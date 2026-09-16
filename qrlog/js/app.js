/**
 * QR-Logbuch — label an installation with a QR code, then keep every service
 * visit in a logbook that the next technician reads before touching anything.
 *
 * The app is a static, offline-first page: all data stays in IndexedDB on the
 * device that entered it, and moves between devices through export/import.
 */

import {
  uid, newAsset, saveAsset, getAsset, allAssets, deleteAsset,
  newEntry, saveEntry, getEntry, deleteEntry, entriesFor, latestEntryByAsset,
  getSettings, saveSettings, shrinkImage, exportAll, importAll,
} from './store.js';
import { qrSvg, assetUrl, idFromScan, qrPngDataUrl } from './qr.js';
import { Scanner, decodeImageFile } from './scanner.js';
import {
  probe, installOnDevice, Dictation, modeLabel, isSupported,
  probeIsBlocked, resetProbeBlock,
} from './stt.js';
import { parseDictation, FIELD_LABELS } from './parse.js';

const $ = (sel) => document.querySelector(sel);
const view = $('#view');

let settings = await getSettings();

/* ---------- Small helpers ---------- */

const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]
  );

/** Multi-line user text for HTML output. */
const escLines = (s) => esc(s).replace(/\n/g, '<br>');

let toastTimer = 0;
function toast(message, ms = 3200) {
  const el = $('#toast');
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), ms);
}

const KINDS = ['Wartung', 'Reparatur', 'Installation', 'Kontrolle', 'Störung', 'Inbetriebnahme'];

function formatDate(iso) {
  if (!iso) return '';
  const [y, m, d] = iso.split('-');
  return d ? `${d}.${m}.${y}` : iso;
}

/** Months between now and `iso`, negative when it is in the past. */
function monthsUntil(iso) {
  if (!iso) return null;
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return null;
  return (then - new Date()) / (1000 * 60 * 60 * 24 * 30.44);
}

function dueBadge(nextService) {
  const months = monthsUntil(nextService);
  if (months === null) return '';
  if (months < 0) return `<span class="badge overdue">Service fällig seit ${formatDate(nextService)}</span>`;
  if (months < 1) return `<span class="badge due">Service am ${formatDate(nextService)}</span>`;
  return `<span class="badge ok">Nächster Service ${formatDate(nextService)}</span>`;
}

function addMonths(iso, months) {
  const date = iso ? new Date(iso) : new Date();
  date.setMonth(date.getMonth() + Number(months || 0));
  return date.toISOString().slice(0, 10);
}

/* ---------- Dictation wiring ---------- */

let activeDictation = null;

function stopDictation() {
  activeDictation?.dictation.stop();
}

/**
 * Wire every `<button data-mic="fieldId">` in the current view to the field it
 * names. Final phrases are appended to what is already there, so dictating and
 * typing mix freely.
 */
function setupDictation(root) {
  for (const button of root.querySelectorAll('[data-mic]')) {
    button.addEventListener('click', () => toggleMic(button));
  }
}

async function toggleMic(button) {
  if (activeDictation?.button === button) {
    stopDictation();
    return;
  }
  stopDictation();

  const field = document.getElementById(button.dataset.mic);
  if (!field) return;

  const status = await probe(settings.lang, { offlineOnly: settings.offlineDictationOnly });
  if (status.mode === 'none') {
    toast(dictationBlockedReason(status));
    return;
  }

  const interimEl = field.parentElement.querySelector('.interim');
  const dictation = new Dictation({
    lang: settings.lang,
    onDevice: status.mode === 'on-device',
    onInterim: (text) => {
      if (interimEl) interimEl.textContent = text;
    },
    onFinal: (text) => {
      const phrase = text.trim();
      if (!phrase) return;
      const needsSpace = field.value && !/\s$/.test(field.value);
      field.value += (needsSpace ? ' ' : '') + phrase;
      field.dispatchEvent(new Event('input', { bubbles: true }));
      if (interimEl) interimEl.textContent = '';
      field.scrollTop = field.scrollHeight;
    },
    onEnd: () => {
      button.classList.remove('recording');
      button.textContent = '🎤';
      if (interimEl) interimEl.textContent = '';
      if (activeDictation?.button === button) activeDictation = null;
    },
    onError: (error) => toast(`Diktat abgebrochen: ${error}`),
  });

  try {
    dictation.start();
  } catch (error) {
    toast(`Diktat konnte nicht starten: ${error.message}`);
    return;
  }
  activeDictation = { button, dictation };
  button.classList.add('recording');
  button.textContent = '⏹';
  toast(`Diktat läuft — ${modeLabel(status.mode)}`, 2000);
}

function dictationBlockedReason(status) {
  if (!isSupported()) return 'Dieser Browser kennt keine Spracherkennung. Bitte tippen.';
  if (probeIsBlocked()) return 'Spracherkennung auf diesem Gerät deaktiviert (siehe Einstellungen).';
  if (status.canInstall) return 'Sprachmodell noch nicht auf dem Gerät — in den Einstellungen installieren.';
  if (settings.offlineDictationOnly) {
    return 'Kein Diktat auf dem Gerät möglich. In den Einstellungen Cloud-Diktat erlauben oder tippen.';
  }
  return 'Diktat ist auf diesem Gerät nicht verfügbar.';
}

/* ---------- Photos ---------- */

/** Pick one photo from the camera or gallery and return a stored photo record. */
function pickPhoto() {
  return new Promise((resolve) => {
    const input = $('#file-photo');
    input.value = '';
    input.onchange = async () => {
      const file = input.files?.[0];
      if (!file) return resolve(null);
      try {
        resolve({ id: uid(8), name: file.name, blob: await shrinkImage(file) });
      } catch (error) {
        toast(`Foto konnte nicht gelesen werden: ${error.message}`);
        resolve(null);
      }
    };
    input.click();
  });
}

const photoUrls = new Set();
function photoUrl(photo) {
  const url = URL.createObjectURL(photo.blob);
  photoUrls.add(url);
  return url;
}
function releasePhotoUrls() {
  for (const url of photoUrls) URL.revokeObjectURL(url);
  photoUrls.clear();
}

function photoGrid(photos, { removable = false } = {}) {
  if (!photos?.length) return '';
  return `<div class="photos">${photos
    .map(
      (p) =>
        `<figure><img src="${photoUrl(p)}" alt="${esc(p.name || 'Foto')}" loading="lazy">` +
        (removable ? `<button class="remove-photo" data-photo="${p.id}" aria-label="Foto entfernen">✕</button>` : '') +
        `</figure>`
    )
    .join('')}</div>`;
}

/* ---------- Router ---------- */

function parseRoute() {
  const hash = location.hash.replace(/^#/, '') || '/';
  const parts = hash.split('/').filter(Boolean);
  if (parts[0] === 'a' && parts[1]) {
    if (parts[2] === 'edit') return { name: 'asset-edit', id: parts[1] };
    if (parts[2] === 'new') return { name: 'entry', id: parts[1], entryId: null };
    if (parts[2] === 'e' && parts[3]) return { name: 'entry', id: parts[1], entryId: parts[3] };
    return { name: 'asset', id: parts[1] };
  }
  if (parts[0] === 'labels') return { name: 'labels' };
  if (parts[0] === 'settings') return { name: 'settings' };
  return { name: 'list' };
}

const ROUTES = {
  list: renderList,
  asset: (route) => renderAsset(route.id),
  'asset-edit': (route) => renderAssetEdit(route.id),
  entry: (route) => renderEntry(route.id, route.entryId),
  labels: renderLabels,
  settings: renderSettings,
};

async function route() {
  stopDictation();
  stopRamble();
  closeRambleSheet();
  releasePhotoUrls();
  $('#menu').hidden = true;
  $('#btn-menu').setAttribute('aria-expanded', 'false');
  const current = parseRoute();
  try {
    await ROUTES[current.name](current);
  } catch (error) {
    console.error(error);
    view.innerHTML = `<section class="card"><h1>Fehler</h1><p>${esc(error.message)}</p></section>`;
  }
  setupDictation(view);
  view.focus({ preventScroll: true });
  window.scrollTo(0, 0);
}

/* ---------- View: asset list ---------- */

async function renderList() {
  const assets = await allAssets();
  const latest = await latestEntryByAsset();

  if (!assets.length) {
    view.innerHTML = `
      <section class="card empty">
        <h1>Noch keine Anlage erfasst</h1>
        <p>Eine Anlage anlegen, QR-Etikett drucken, aufkleben — ab dann hält jeder
           Serviceeinsatz sich selbst fest.</p>
        <div class="row">
          <button class="primary" id="btn-new-asset">+ Neue Anlage</button>
          <button id="btn-demo">Beispiel laden</button>
        </div>
      </section>`;
    $('#btn-new-asset').onclick = createAsset;
    $('#btn-demo').onclick = loadDemo;
    return;
  }

  const rows = assets
    .map((asset) => {
      const last = latest.get(asset.id);
      return `
        <a class="asset-row" href="#/a/${asset.id}">
          <div class="asset-qr">${qrSvg(assetUrl(asset.id))}</div>
          <div class="asset-main">
            <strong>${esc(asset.name || 'Ohne Namen')}</strong>
            <span class="muted">${esc([asset.type, asset.location].filter(Boolean).join(' · '))}</span>
            ${last ? `<span class="muted">Zuletzt ${formatDate(last.date)} — ${esc(last.kind)}${last.technician ? `, ${esc(last.technician)}` : ''}</span>` : '<span class="muted">Noch kein Eintrag</span>'}
            ${last ? dueBadge(last.nextService) : ''}
          </div>
        </a>`;
    })
    .join('');

  view.innerHTML = `
    <section class="list-head">
      <h1>Anlagen <span class="muted">(${assets.length})</span></h1>
      <button class="primary" id="btn-new-asset">+ Neue Anlage</button>
    </section>
    <input id="filter" type="search" placeholder="Suchen — Name, Typ, Standort" autocomplete="off" />
    <div id="asset-list">${rows}</div>`;

  $('#btn-new-asset').onclick = createAsset;
  $('#filter').addEventListener('input', (event) => {
    const needle = event.target.value.toLowerCase();
    for (const row of view.querySelectorAll('.asset-row')) {
      row.hidden = needle !== '' && !row.textContent.toLowerCase().includes(needle);
    }
  });
}

async function createAsset(id = uid()) {
  const asset = newAsset(id);
  await saveAsset(asset);
  location.hash = `#/a/${asset.id}/edit`;
}

/* ---------- View: one asset ---------- */

async function renderAsset(id) {
  const asset = await getAsset(id);
  if (!asset) return renderUnknownAsset(id);
  const entries = await entriesFor(id);
  const last = entries[0];

  const facts = [
    ['Typ', asset.type],
    ['Standort', asset.location],
    ['Hersteller', asset.manufacturer],
    ['Modell', asset.model],
    ['Seriennummer', asset.serial],
    ['In Betrieb seit', formatDate(asset.installedOn)],
    ['Serviceintervall', asset.intervalMonths ? `${asset.intervalMonths} Monate` : ''],
  ].filter(([, value]) => value);

  view.innerHTML = `
    <section class="card asset-head">
      <div class="asset-qr large" id="qr-box" title="QR-Code — antippen zum Vergrössern">${qrSvg(assetUrl(id))}</div>
      <div>
        <h1>${esc(asset.name || 'Ohne Namen')}</h1>
        <p class="muted">${esc([asset.type, asset.location].filter(Boolean).join(' · '))}</p>
        ${last ? dueBadge(last.nextService) : ''}
        <p class="code">ID ${esc(id)}</p>
      </div>
    </section>

    <div class="row">
      <button class="primary big" id="btn-new-entry">+ Eintrag: Was habe ich gemacht?</button>
    </div>
    <div class="row">
      <a class="button" href="#/a/${id}/edit">Anlage bearbeiten</a>
      <button id="btn-qr-png">QR als PNG</button>
      <button id="btn-print-one">Etikett drucken</button>
    </div>

    ${facts.length ? `<section class="card"><h2>Anlagedaten</h2><dl class="facts">${facts
      .map(([label, value]) => `<dt>${esc(label)}</dt><dd>${esc(value)}</dd>`)
      .join('')}</dl></section>` : ''}

    ${asset.notes ? `<section class="card"><h2>Notizen zur Anlage</h2><p>${escLines(asset.notes)}</p></section>` : ''}
    ${asset.photos?.length ? `<section class="card"><h2>Fotos</h2>${photoGrid(asset.photos)}</section>` : ''}

    <section class="card">
      <h2>Logbuch <span class="muted">(${entries.length})</span></h2>
      ${entries.length ? `<ol class="timeline">${entries.map(entryCard).join('')}</ol>`
        : '<p class="muted">Noch kein Eintrag. Der erste Eintrag ist das, was der nächste Techniker in einem Jahr liest.</p>'}
    </section>`;

  $('#btn-new-entry').onclick = () => (location.hash = `#/a/${id}/new`);
  $('#btn-qr-png').onclick = async () => {
    const url = await qrPngDataUrl(assetUrl(id));
    const a = document.createElement('a');
    a.href = url;
    a.download = `qr-${asset.name ? asset.name.replace(/\W+/g, '-').toLowerCase() : id}.png`;
    a.click();
  };
  $('#btn-print-one').onclick = () => (location.hash = `#/labels?only=${id}`);
  $('#qr-box').onclick = () => $('#qr-box').classList.toggle('zoomed');
}

function entryCard(entry) {
  const detail = (label, value) =>
    value ? `<div class="entry-detail"><span>${label}</span><p>${escLines(value)}</p></div>` : '';
  return `
    <li class="entry">
      <header>
        <strong>${formatDate(entry.date)}</strong>
        <span class="kind">${esc(entry.kind)}</span>
        ${entry.technician ? `<span class="muted">${esc(entry.technician)}${entry.company ? `, ${esc(entry.company)}` : ''}</span>` : ''}
        <a class="edit-link" href="#/a/${entry.assetId}/e/${entry.id}">bearbeiten</a>
      </header>
      ${detail('Ausgeführte Arbeiten', entry.work)}
      ${detail('Befund / Zustand', entry.findings)}
      ${detail('Material', entry.parts)}
      ${entry.nextService ? `<div class="entry-detail"><span>Nächster Service</span><p>${formatDate(entry.nextService)}</p></div>` : ''}
      ${photoGrid(entry.photos)}
    </li>`;
}

/** A scanned code we have never seen — usually a blank pre-printed label. */
function renderUnknownAsset(id) {
  view.innerHTML = `
    <section class="card empty">
      <h1>Unbekannter QR-Code</h1>
      <p>Die ID <span class="code">${esc(id)}</span> ist auf diesem Gerät nicht gespeichert.</p>
      <p class="muted">Entweder gehört das Etikett zu einem anderen Gerät — dann dessen Export
         importieren — oder es ist ein leeres Etikett, das jetzt einer Anlage zugeordnet wird.</p>
      <div class="row">
        <button class="primary" id="btn-adopt">Anlage mit dieser ID anlegen</button>
        <a class="button" href="#/">Zur Übersicht</a>
      </div>
    </section>`;
  $('#btn-adopt').onclick = () => createAsset(id);
}

/* ---------- View: edit asset ---------- */

async function renderAssetEdit(id) {
  const asset = (await getAsset(id)) ?? newAsset(id);
  const field = (name, label, type = 'text', value = asset[name]) => `
    <label>${esc(label)}
      <input name="${name}" type="${type}" value="${esc(value ?? '')}" />
    </label>`;

  view.innerHTML = `
    <form id="asset-form" class="card">
      <h1>Anlage</h1>
      ${field('name', 'Bezeichnung (z. B. Wärmepumpe Keller)')}
      ${field('type', 'Anlagetyp')}
      ${field('location', 'Standort')}
      ${field('manufacturer', 'Hersteller')}
      ${field('model', 'Modell / Typenbezeichnung')}
      ${field('serial', 'Seriennummer')}
      ${field('installedOn', 'In Betrieb seit', 'date')}
      ${field('intervalMonths', 'Serviceintervall (Monate)', 'number')}
      <label>Notizen — was ist das für eine Anlage, was muss man wissen?
        <div class="dictate">
          <textarea id="asset-notes" name="notes" rows="5">${esc(asset.notes)}</textarea>
          <button type="button" class="mic" data-mic="asset-notes" aria-label="Diktieren">🎤</button>
        </div>
        <span class="interim"></span>
      </label>

      <div class="photo-block">
        <h2>Fotos</h2>
        <div id="asset-photos">${photoGrid(asset.photos, { removable: true })}</div>
        <button type="button" id="btn-add-photo">📷 Foto aufnehmen</button>
      </div>

      <div class="row">
        <button type="submit" class="primary">Speichern</button>
        <a class="button" href="#/a/${id}">Abbrechen</a>
        <button type="button" id="btn-delete" class="danger">Anlage löschen</button>
      </div>
    </form>`;

  let photos = [...(asset.photos ?? [])];
  const refreshPhotos = () => {
    $('#asset-photos').innerHTML = photoGrid(photos, { removable: true });
    bindRemove();
  };
  const bindRemove = () => {
    for (const button of view.querySelectorAll('.remove-photo')) {
      button.onclick = () => {
        photos = photos.filter((p) => p.id !== button.dataset.photo);
        refreshPhotos();
      };
    }
  };
  bindRemove();

  $('#btn-add-photo').onclick = async () => {
    const photo = await pickPhoto();
    if (photo) {
      photos.push(photo);
      refreshPhotos();
    }
  };

  $('#btn-delete').onclick = async () => {
    if (!confirm('Anlage mit allen Logbucheinträgen löschen?')) return;
    await deleteAsset(id);
    location.hash = '#/';
  };

  $('#asset-form').onsubmit = async (event) => {
    event.preventDefault();
    stopDictation();
    const form = new FormData(event.target);
    const updated = { ...asset, photos };
    for (const [key, value] of form.entries()) updated[key] = value;
    updated.intervalMonths = Number(updated.intervalMonths) || 0;
    await saveAsset(updated);
    toast('Gespeichert.');
    location.hash = `#/a/${id}`;
  };
}

/* ---------- View: logbook entry ---------- */

const draftKey = (assetId) => `qrlog:draft:${assetId}`;

async function renderEntry(assetId, entryId) {
  const asset = await getAsset(assetId);
  if (!asset) return renderUnknownAsset(assetId);

  const existing = entryId ? await getEntry(entryId) : null;
  const draft = entryId ? null : readDraft(assetId);
  const entry = existing ?? { ...newEntry(assetId), ...(draft ?? {}) };
  if (!existing && !draft) {
    entry.technician = settings.technician;
    entry.company = settings.company;
    entry.nextService = addMonths(entry.date, asset.intervalMonths);
  }

  view.innerHTML = `
    <form id="entry-form" class="card">
      <h1>${existing ? 'Eintrag bearbeiten' : 'Neuer Eintrag'}</h1>
      <p class="muted">${esc(asset.name || assetId)}</p>

      <label class="hero">Was wurde heute gemacht?
        <div class="dictate">
          <textarea id="entry-work" name="work" rows="7" placeholder="Filter ersetzt, Vordruck auf 1.4 bar ergänzt, Umwälzpumpe lief unruhig — beobachten."></textarea>
          <button type="button" class="mic" data-mic="entry-work" aria-label="Diktieren">🎤</button>
        </div>
        <span class="interim"></span>
      </label>

      <div class="grid-2">
        <label>Datum<input name="date" type="date" value="${esc(entry.date)}" required /></label>
        <label>Art
          <select name="kind">
            ${KINDS.map((k) => `<option${k === entry.kind ? ' selected' : ''}>${k}</option>`).join('')}
          </select>
        </label>
        <label>Techniker<input name="technician" value="${esc(entry.technician)}" /></label>
        <label>Firma<input name="company" value="${esc(entry.company)}" /></label>
      </div>

      <label>Befund / Zustand der Anlage
        <div class="dictate">
          <textarea id="entry-findings" name="findings" rows="3"></textarea>
          <button type="button" class="mic" data-mic="entry-findings" aria-label="Diktieren">🎤</button>
        </div>
        <span class="interim"></span>
      </label>

      <label>Verbautes Material
        <div class="dictate">
          <textarea id="entry-parts" name="parts" rows="2"></textarea>
          <button type="button" class="mic" data-mic="entry-parts" aria-label="Diktieren">🎤</button>
        </div>
        <span class="interim"></span>
      </label>

      <label>Nächster Service
        <input name="nextService" type="date" value="${esc(entry.nextService)}" />
      </label>

      <div class="photo-block">
        <h2>Fotos</h2>
        <div id="entry-photos">${photoGrid(entry.photos, { removable: true })}</div>
        <button type="button" id="btn-add-photo">📷 Foto aufnehmen</button>
      </div>

      <div class="row">
        <button type="submit" class="primary big">Eintrag speichern</button>
        <a class="button" href="#/a/${assetId}">Abbrechen</a>
        ${existing ? '<button type="button" id="btn-delete-entry" class="danger">Eintrag löschen</button>' : ''}
      </div>
      <p class="muted" id="draft-note"></p>
    </form>

    <div id="ramble-bar">
      <div id="ramble-live" hidden>
        <p class="muted">Einfach erzählen: was gemacht, was aufgefallen, was verbaut, wann wieder.</p>
        <p id="ramble-text"></p>
      </div>
      <button type="button" id="btn-ramble" class="primary big">🎤 Einfach erzählen</button>
    </div>

    <div id="ramble-sheet" class="overlay sheet" hidden>
      <div class="sheet-body">
        <h1>Vorschlag</h1>
        <p class="muted">Übernommen wird nur, was angehakt ist.</p>
        <div id="ramble-proposal"></div>
        <details id="ramble-raw"><summary>Gesagter Text</summary><p></p></details>
        <div class="row">
          <button type="button" id="ramble-apply" class="primary">Übernehmen</button>
          <button type="button" id="ramble-all-work">Alles in «Arbeiten»</button>
          <button type="button" id="ramble-discard">Verwerfen</button>
        </div>
      </div>
    </div>`;

  // Textareas are filled after render so user text is never parsed as markup.
  $('#entry-work').value = entry.work ?? '';
  $('#entry-findings').value = entry.findings ?? '';
  $('#entry-parts').value = entry.parts ?? '';

  let photos = [...(entry.photos ?? [])];
  const refreshPhotos = () => {
    $('#entry-photos').innerHTML = photoGrid(photos, { removable: true });
    for (const button of view.querySelectorAll('.remove-photo')) {
      button.onclick = () => {
        photos = photos.filter((p) => p.id !== button.dataset.photo);
        refreshPhotos();
      };
    }
  };
  refreshPhotos();

  $('#btn-add-photo').onclick = async () => {
    const photo = await pickPhoto();
    if (photo) {
      photos.push(photo);
      refreshPhotos();
    }
  };

  const form = $('#entry-form');

  // Keep an unsaved new entry in localStorage: dictating a long entry and then
  // losing the tab in a cellar is exactly the case this app must not lose.
  if (!existing) {
    form.addEventListener('input', () => {
      const data = Object.fromEntries(new FormData(form).entries());
      localStorage.setItem(draftKey(assetId), JSON.stringify({ ...data, id: entry.id }));
      $('#draft-note').textContent = 'Entwurf automatisch gesichert.';
    });
    if (draft) $('#draft-note').textContent = 'Entwurf von vorhin wiederhergestellt.';
  }

  if (existing) {
    $('#btn-delete-entry').onclick = async () => {
      if (!confirm('Diesen Logbucheintrag löschen?')) return;
      await deleteEntry(existing.id);
      location.hash = `#/a/${assetId}`;
    };
  }

  setupRamble();

  form.onsubmit = async (event) => {
    event.preventDefault();
    stopDictation();
    stopRamble();
    const data = Object.fromEntries(new FormData(form).entries());
    const saved = { ...entry, ...data, assetId, photos };
    if (!saved.work.trim() && !saved.findings.trim()) {
      toast('Bitte mindestens festhalten, was gemacht wurde.');
      return;
    }
    await saveEntry(saved);
    localStorage.removeItem(draftKey(assetId));

    // Remember who is working, so the next entry on this device is prefilled.
    if (saved.technician !== settings.technician || saved.company !== settings.company) {
      settings = { ...settings, technician: saved.technician, company: saved.company };
      await saveSettings(settings);
    }
    toast('Eintrag gespeichert.');
    location.hash = `#/a/${assetId}`;
  };
}

/* ---------- Ramble: one dictation, sorted into the fields ---------- */

/**
 * The bar pinned to the bottom of the entry form. A technician holds it down
 * and talks once — what they did, what they noticed, what they fitted, when
 * they will be back — and the parser proposes where each sentence belongs.
 *
 * Nothing is written into the form until the proposal is confirmed: the parser
 * is a set of German rules, not a mind reader, and silently rewriting someone's
 * service record would be worse than making them type it.
 */
let ramble = null;

function setupRamble() {
  const button = $('#btn-ramble');
  if (!button) return;
  button.onclick = () => (ramble ? stopRamble() : startRamble());
  $('#ramble-discard').onclick = closeRambleSheet;
}

async function startRamble() {
  const status = await probe(settings.lang, { offlineOnly: settings.offlineDictationOnly });
  if (status.mode === 'none') {
    toast(dictationBlockedReason(status));
    return;
  }

  stopDictation(); // Only one microphone.
  const button = $('#btn-ramble');
  const live = $('#ramble-live');
  const text = $('#ramble-text');
  let transcript = '';

  const dictation = new Dictation({
    lang: settings.lang,
    onDevice: status.mode === 'on-device',
    onInterim: (interim) => {
      text.textContent = `${transcript} ${interim}`.trim();
      text.scrollTop = text.scrollHeight;
    },
    onFinal: (phrase) => {
      transcript = `${transcript} ${phrase.trim()}`.trim();
      text.textContent = transcript;
      text.scrollTop = text.scrollHeight;
    },
    onEnd: () => finishRamble(),
    onError: (error) => {
      toast(`Diktat abgebrochen: ${error}`);
      finishRamble();
    },
  });

  try {
    dictation.start();
  } catch (error) {
    toast(`Diktat konnte nicht starten: ${error.message}`);
    return;
  }

  ramble = { dictation, get transcript() { return transcript; } };
  live.hidden = false;
  text.textContent = '';
  button.textContent = '⏹ Fertig — Vorschlag anzeigen';
  button.classList.add('recording');
  toast(`Aufnahme läuft — ${modeLabel(status.mode)}`, 2000);
}

function stopRamble() {
  ramble?.dictation.stop();
}

/** Called once the recogniser has actually ended, from stop or from an error. */
function finishRamble() {
  if (!ramble) return;
  const transcript = ramble.transcript;
  ramble = null;

  const button = $('#btn-ramble');
  if (button) {
    button.textContent = '🎤 Einfach erzählen';
    button.classList.remove('recording');
  }
  const live = $('#ramble-live');
  if (live) live.hidden = true;

  if (!transcript.trim()) {
    toast('Nichts verstanden.');
    return;
  }
  showRambleProposal(transcript);
}

function showRambleProposal(transcript) {
  const result = parseDictation(transcript);
  const rows = [];

  for (const field of ['work', 'findings', 'parts']) {
    if (result[field]) rows.push({ field, label: FIELD_LABELS[field], value: result[field] });
  }
  if (result.nextService) {
    rows.push({ field: 'nextService', label: FIELD_LABELS.nextService, value: result.nextService, display: formatDate(result.nextService) });
  }
  if (result.kind) rows.push({ field: 'kind', label: 'Art', value: result.kind });
  if (result.date) rows.push({ field: 'date', label: 'Datum', value: result.date, display: formatDate(result.date) });

  $('#ramble-proposal').innerHTML = rows
    .map(
      (row, index) => `
        <label class="proposal">
          <input type="checkbox" checked data-index="${index}" />
          <span>
            <em>${esc(row.label)}</em>
            ${escLines(row.display ?? row.value)}
          </span>
        </label>`
    )
    .join('');
  $('#ramble-raw').querySelector('p').textContent = transcript;
  $('#ramble-sheet').hidden = false;

  $('#ramble-apply').onclick = () => {
    const checked = [...$('#ramble-proposal').querySelectorAll('input:checked')].map(
      (input) => rows[Number(input.dataset.index)]
    );
    for (const row of checked) applyProposal(row.field, row.value);
    closeRambleSheet();
    toast(checked.length ? `${checked.length} Feld(er) übernommen.` : 'Nichts übernommen.');
  };

  // The escape hatch for when the routing guessed wrong: keep every word,
  // in one field, and let the technician move what belongs elsewhere.
  $('#ramble-all-work').onclick = () => {
    applyProposal('work', transcript.trim());
    closeRambleSheet();
    toast('Ganzer Text in «Ausgeführte Arbeiten».');
  };
}

function closeRambleSheet() {
  const sheet = $('#ramble-sheet');
  if (sheet) sheet.hidden = true;
}

/** Proposals are appended, never overwritten — except the single-value fields. */
function applyProposal(field, value) {
  if (field === 'kind' || field === 'date' || field === 'nextService') {
    const input = $(`#entry-form [name="${field}"]`);
    if (input) input.value = value;
  } else {
    const area = $(`#entry-${field}`);
    if (!area) return;
    const existing = area.value.trim();
    area.value = existing ? `${existing} ${value}` : value;
  }
  $('#entry-form')?.dispatchEvent(new Event('input', { bubbles: true }));
}

function readDraft(assetId) {
  try {
    const raw = localStorage.getItem(draftKey(assetId));
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

/* ---------- View: printable labels ---------- */

async function renderLabels() {
  const only = new URLSearchParams(location.hash.split('?')[1] ?? '').get('only');
  const assets = only ? [await getAsset(only)].filter(Boolean) : await allAssets();

  view.innerHTML = `
    <section class="card no-print">
      <h1>Etiketten drucken</h1>
      <p class="muted">Auf wetterfeste Klebeetiketten drucken. Mindestens 25 mm Kantenlänge,
         sonst tut sich eine Handykamera im Technikraum schwer.</p>
      <div class="row">
        <button class="primary" id="btn-print">Drucken</button>
        <button id="btn-blank">10 Blanko-Etiketten</button>
        <a class="button" href="#/">Zurück</a>
      </div>
    </section>
    <div class="labels" id="labels">${assets.map(labelHtml).join('')}</div>`;

  $('#btn-print').onclick = () => window.print();
  $('#btn-blank').onclick = () => {
    // Blank labels carry a fresh id but no asset yet: stick one on, scan it,
    // and the app offers to create the asset right there on site.
    const blanks = Array.from({ length: 10 }, () => ({ id: uid(), name: '', location: '' }));
    $('#labels').innerHTML = blanks.map(labelHtml).join('');
  };
}

function labelHtml(asset) {
  return `
    <figure class="label">
      <div class="label-qr">${qrSvg(assetUrl(asset.id))}</div>
      <figcaption>
        <strong>${esc(asset.name || 'Blanko')}</strong>
        <span>${esc(asset.location || 'scannen zum Anlegen')}</span>
        <span class="code">${esc(asset.id)}</span>
      </figcaption>
    </figure>`;
}

/* ---------- View: settings ---------- */

async function renderSettings() {
  // The dictation probe talks to the browser's speech service and can take a
  // moment (or, on some builds, not answer at all), so the page renders first
  // and the status fills itself in.
  view.innerHTML = `
    <section class="card">
      <h1>Einstellungen</h1>
      <label>Techniker<input id="set-technician" value="${esc(settings.technician)}" /></label>
      <label>Firma<input id="set-company" value="${esc(settings.company)}" /></label>
      <label>Sprache für Diktat
        <select id="set-lang">
          ${['de-CH', 'de-DE', 'fr-CH', 'it-CH', 'en-GB']
            .map((l) => `<option${l === settings.lang ? ' selected' : ''}>${l}</option>`)
            .join('')}
        </select>
      </label>
    </section>

    <section class="card">
      <h2>Diktat</h2>
      <p>Status: <strong id="stt-status">noch nicht geprüft</strong></p>
      <label class="switch">
        <input id="set-offline-only" type="checkbox" ${settings.offlineDictationOnly ? 'checked' : ''} />
        Nur Diktat auf dem Gerät zulassen
      </label>
      <p class="muted">Eingeschaltet wird nie Audio verschickt. Ausgeschaltet darf das Mikrofon
         auf die Cloud-Spracherkennung des Browsers ausweichen (Chrome: Google, Safari: Apple) —
         das braucht Internet und die Aufnahme verlässt das Gerät.</p>
      <div class="row">
        <button id="btn-check-stt">Diktat prüfen</button>
      </div>
      <div id="stt-install"></div>
    </section>

    <section class="card">
      <h2>Daten</h2>
      <p class="muted">Alles liegt nur auf diesem Gerät. Für ein zweites Gerät oder als Sicherung:
         exportieren und dort importieren.</p>
      <div class="row">
        <button id="btn-export-2">Exportieren</button>
        <button id="btn-import-2">Importieren</button>
      </div>
    </section>`;

  const persist = async (patch) => {
    settings = { ...settings, ...patch };
    await saveSettings(settings);
  };
  $('#set-technician').onchange = (e) => persist({ technician: e.target.value });
  $('#set-company').onchange = (e) => persist({ company: e.target.value });
  $('#set-lang').onchange = async (e) => {
    await persist({ lang: e.target.value });
    route();
  };
  $('#set-offline-only').onchange = async (e) => {
    await persist({ offlineDictationOnly: e.target.checked });
    route();
  };
  $('#btn-export-2').onclick = doExport;
  $('#btn-import-2').onclick = () => $('#file-import').click();

  // Deliberately not automatic: asking the browser about speech support means
  // waking its speech service, and a broken one can take the page down with
  // it. Nothing here touches the microphone stack until the user asks.
  $('#btn-check-stt').onclick = () => {
    $('#stt-status').textContent = 'wird geprüft …';
    fillDictationStatus();
  };
  if (probeIsBlocked()) fillDictationStatus();
}

async function fillDictationStatus() {
  const [status, rawStatus] = await Promise.all([
    probe(settings.lang, { offlineOnly: settings.offlineDictationOnly }),
    probe(settings.lang, { offlineOnly: false }),
  ]);
  const label = $('#stt-status');
  if (!label) return; // The user navigated away while we were probing.
  label.textContent = statusText(status, rawStatus);

  const host = $('#stt-install');
  if (probeIsBlocked()) {
    host.innerHTML = '<button id="btn-reset-probe">Prüfung erneut versuchen</button>';
    $('#btn-reset-probe').onclick = () => {
      resetProbeBlock();
      route();
    };
    return;
  }
  if (!status.canInstall && !rawStatus.canInstall) return;
  host.innerHTML = '<button id="btn-install-stt">Sprachmodell auf dem Gerät installieren</button>';
  const install = $('#btn-install-stt');
  install.onclick = async () => {
    install.disabled = true;
    install.textContent = 'Wird geladen …';
    try {
      const ok = await installOnDevice(settings.lang);
      toast(ok ? 'Sprachmodell installiert.' : 'Installation nicht abgeschlossen.');
    } catch (error) {
      toast(`Installation fehlgeschlagen: ${error.message}`);
    }
    route();
  };
}

function statusText(status, rawStatus) {
  if (!isSupported()) return 'Keine Spracherkennung in diesem Browser — bitte tippen.';
  if (probeIsBlocked()) return 'Prüfung hat den Browser beim letzten Mal abstürzen lassen — übersprungen.';
  if (status.mode === 'on-device') return 'Auf dem Gerät, offline nutzbar.';
  if (rawStatus.state === 'downloadable') return 'Sprachmodell kann auf das Gerät geladen werden.';
  if (rawStatus.state === 'downloading') return 'Sprachmodell wird geladen …';
  if (settings.offlineDictationOnly) return 'Nur auf dem Gerät erlaubt — hier nicht verfügbar.';
  return 'Nur Cloud-Spracherkennung verfügbar (Audio verlässt das Gerät).';
}

/* ---------- Export / import ---------- */

async function doExport() {
  const data = await exportAll();
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `qr-logbuch-${new Date().toISOString().slice(0, 10)}.json`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

$('#file-import').addEventListener('change', async (event) => {
  const file = event.target.files?.[0];
  event.target.value = '';
  if (!file) return;
  try {
    const result = await importAll(JSON.parse(await file.text()));
    toast(`${result.added} Anlagen neu, ${result.updated} aktualisiert, ${result.entriesAdded} Einträge.`);
    route();
  } catch (error) {
    toast(`Import fehlgeschlagen: ${error.message}`);
  }
});

/* ---------- Scanner ---------- */

const scanner = new Scanner($('#scanner-video'));

async function openScanner() {
  $('#scanner').hidden = false;
  try {
    await scanner.start(handleScan);
  } catch (error) {
    closeScanner();
    toast(`Kamera nicht verfügbar: ${error.message}. Stattdessen «Aus Foto lesen».`);
  }
}

function closeScanner() {
  scanner.stop();
  $('#scanner').hidden = true;
}

function handleScan(text) {
  closeScanner();
  const id = idFromScan(text);
  if (!id) {
    toast('Das ist kein QR-Logbuch-Code.');
    return;
  }
  location.hash = `#/a/${id}`;
}

$('#btn-scan').onclick = openScanner;
$('#scanner-close').onclick = closeScanner;
$('#scanner-file').onclick = () => $('#file-scan').click();
$('#file-scan').addEventListener('change', async (event) => {
  const file = event.target.files?.[0];
  event.target.value = '';
  if (!file) return;
  try {
    const text = await decodeImageFile(file);
    if (text) handleScan(text);
    else toast('Auf dem Foto war kein QR-Code lesbar.');
  } catch (error) {
    toast(`Foto konnte nicht gelesen werden: ${error.message}`);
  }
});

/* ---------- Demo data ---------- */

async function loadDemo() {
  const asset = {
    ...newAsset(),
    name: 'Wärmepumpe Keller',
    type: 'Sole/Wasser-Wärmepumpe',
    location: 'UG, Technikraum 2',
    manufacturer: 'Beispiel AG',
    model: 'WP-120 S',
    serial: 'SN-2024-88213',
    installedOn: '2024-03-11',
    intervalMonths: 12,
    notes: 'Soledruck im Betrieb 1.4–1.6 bar. Absperrhahn Rücklauf klemmt, mit Gefühl schliessen.',
  };
  await saveAsset(asset);
  await saveEntry({
    ...newEntry(asset.id),
    date: '2025-03-14',
    technician: 'M. Keller',
    company: 'Beispiel Haustechnik',
    kind: 'Wartung',
    work: 'Jahreswartung: Soledruck geprüft (1.5 bar), Filter gereinigt, Fehlerspeicher ausgelesen und geleert, Vorlauftemperatur auf 34 °C reduziert.',
    findings: 'Umwälzpumpe läuft leicht unruhig beim Anlauf — nächstes Jahr prüfen, evtl. Lager.',
    parts: 'Solefilter-Einsatz 1×',
    nextService: '2026-03-14',
  });
  toast('Beispielanlage angelegt.');
  location.hash = `#/a/${asset.id}`;
  route();
}

/* ---------- Boot ---------- */

$('#btn-menu').onclick = () => {
  const menu = $('#menu');
  menu.hidden = !menu.hidden;
  $('#btn-menu').setAttribute('aria-expanded', String(!menu.hidden));
};
$('#btn-export').onclick = doExport;
$('#btn-import').onclick = () => $('#file-import').click();

document.addEventListener('click', (event) => {
  if (!event.target.closest('#menu') && !event.target.closest('#btn-menu')) {
    $('#menu').hidden = true;
  }
});

window.addEventListener('hashchange', route);
window.addEventListener('pagehide', () => {
  stopDictation();
  stopRamble();
});
await route();

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(() => {
    /* Offline caching is a bonus; the app works without it. */
  });
}
