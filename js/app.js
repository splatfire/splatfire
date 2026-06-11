import { PanoViewer } from 'viewer';
import { measurementLabel, isFloorPoint, DEFAULT_CAMERA_HEIGHT } from 'measure';
import { createDemoTour } from './demo.js';
import { RoomCapture } from './capture.js';
import { exportProjectLink } from './share.js';
import { uid, saveTour, loadTour, clearTour, exportTour, importTour } from './store.js';

const $ = (sel) => document.querySelector(sel);

const viewer = new PanoViewer($('#viewer'));
const capture = new RoomCapture();

let tour = { id: uid(), name: 'Untitled tour', startSceneId: null, scenes: [] };
let currentSceneId = null;
let mode = 'edit'; // 'edit' | 'view'

const currentScene = () => tour.scenes.find((s) => s.id === currentSceneId) ?? null;

let saveTimer = null;
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    saveTimer = null;
    saveTour(tour).catch(console.error);
  }, 300);
}

// Flush a pending debounced save when the page is being closed or hidden,
// so quick edit-then-close doesn't lose the last change.
window.addEventListener('pagehide', () => {
  if (saveTimer === null) return;
  clearTimeout(saveTimer);
  saveTimer = null;
  saveTour(tour).catch(console.error);
});

/* ---------- Rendering ---------- */

function renderAll() {
  $('#tour-name').value = tour.name;
  $('#empty-state').hidden = tour.scenes.length > 0;
  renderSceneList();
  renderHotspots();
  renderMeasurements();
}

function renderSceneList() {
  const ul = $('#scene-list');
  ul.replaceChildren();
  for (const scene of tour.scenes) {
    const li = document.createElement('li');
    li.classList.toggle('active', scene.id === currentSceneId);

    const name = document.createElement('span');
    name.className = 'scene-name';
    name.textContent = scene.name;
    li.appendChild(name);

    if (scene.id === tour.startSceneId) {
      const mark = document.createElement('span');
      mark.className = 'start-mark';
      mark.title = 'Tour starts here';
      mark.textContent = '★';
      li.appendChild(mark);
    }

    const actions = document.createElement('span');
    actions.className = 'scene-actions';
    for (const [icon, title, fn] of [
      ['★', 'Set as start room', () => setStartScene(scene.id)],
      ['✎', 'Rename room', () => renameScene(scene.id)],
      ['✕', 'Delete room', () => deleteScene(scene.id)],
    ]) {
      const b = document.createElement('button');
      b.textContent = icon;
      b.title = title;
      b.addEventListener('click', (e) => { e.stopPropagation(); fn(); });
      actions.appendChild(b);
    }
    li.appendChild(actions);

    li.addEventListener('click', () => showScene(scene.id));
    ul.appendChild(li);
  }
}

function renderHotspots(extra = []) {
  const scene = currentScene();
  if (!scene) {
    viewer.setHotspots([]);
    return;
  }
  const spots = (scene.hotspots ?? []).map((h) => ({
    lon: h.lon,
    lat: h.lat,
    type: h.type,
    label: h.type === 'link'
      ? tour.scenes.find((s) => s.id === h.targetSceneId)?.name ?? '(missing room)'
      : h.title,
    onClick: () => onHotspotClick(scene, h),
  }));
  viewer.setHotspots([...spots, ...extra]);
}

function renderMeasurements() {
  const scene = currentScene();
  if (!scene) {
    viewer.setLines([]);
    return;
  }
  scene.measurements ??= [];
  viewer.setLines(scene.measurements.map((m) => ({
    a: m.a,
    b: m.b,
    label: measurementLabel(m, scene.cameraHeight ?? DEFAULT_CAMERA_HEIGHT),
    onClick: () => {
      if (mode !== 'edit') return;
      if (!confirm('Delete this measurement?')) return;
      scene.measurements = scene.measurements.filter((x) => x.id !== m.id);
      persist();
      renderMeasurements();
    },
  })));
}

// Guards against out-of-order panorama loads when rooms are switched rapidly:
// only the most recent showScene call gets to render its hotspots and lines.
let showSceneToken = 0;

async function showScene(id) {
  const scene = tour.scenes.find((s) => s.id === id);
  if (!scene) return;
  const token = ++showSceneToken;
  currentSceneId = id;
  renderSceneList();
  try {
    await viewer.showPanorama(scene.image, scene.view);
  } catch (err) {
    console.error('Failed to display room', err);
    if (token === showSceneToken) {
      alert(`Could not display "${scene.name}" — the image may be corrupt.`);
    }
    return;
  }
  if (token !== showSceneToken) return;
  renderHotspots();
  renderMeasurements();
}

/* ---------- Scene management ---------- */

function makeScene(name, imageBlob) {
  return {
    id: uid(),
    name,
    image: imageBlob,
    view: { lon: 0, lat: 0 },
    hotspots: [],
    measurements: [],
  };
}

async function addScene(scene) {
  tour.scenes.push(scene);
  tour.startSceneId ??= scene.id;
  persist();
  renderAll();
  await showScene(scene.id);
}

async function addSceneFiles(files) {
  const images = [...files].filter((f) => f.type.startsWith('image/'));
  let last = null;
  for (const file of images) {
    last = makeScene(file.name.replace(/\.[^.]+$/, '') || 'Room', file);
    tour.scenes.push(last);
    tour.startSceneId ??= last.id;
  }
  if (!last) return;
  persist();
  renderAll();
  await showScene(last.id);
}

function setStartScene(id) {
  tour.startSceneId = id;
  persist();
  renderSceneList();
}

function renameScene(id) {
  const scene = tour.scenes.find((s) => s.id === id);
  const name = prompt('Room name', scene.name);
  if (!name?.trim()) return;
  scene.name = name.trim();
  persist();
  renderSceneList();
  renderHotspots(); // link labels show room names
}

function deleteScene(id) {
  const scene = tour.scenes.find((s) => s.id === id);
  if (!confirm(`Delete room "${scene.name}"? Links pointing to it are removed too.`)) return;
  tour.scenes = tour.scenes.filter((s) => s.id !== id);
  for (const s of tour.scenes) {
    s.hotspots = (s.hotspots ?? []).filter((h) => h.targetSceneId !== id);
  }
  if (tour.startSceneId === id) tour.startSceneId = tour.scenes[0]?.id ?? null;
  persist();
  if (currentSceneId === id) {
    currentSceneId = null;
    if (tour.scenes.length) {
      showScene(tour.startSceneId);
    } else {
      viewer.clearPanorama();
    }
  }
  renderAll();
}

/* ---------- Hotspots ---------- */

function onHotspotClick(scene, hotspot) {
  if (mode === 'edit') {
    if (hotspot.type === 'link') editLinkHotspot(scene, hotspot);
    else editInfoHotspot(scene, hotspot);
  } else if (hotspot.type === 'link') {
    if (tour.scenes.some((s) => s.id === hotspot.targetSceneId)) {
      showScene(hotspot.targetSceneId);
    }
  } else {
    $('#note-view-title').textContent = hotspot.title;
    $('#note-view-text').textContent = hotspot.text || '';
    $('#dlg-note-view').showModal();
  }
}

function startPlacement(message, onClick) {
  $('#viewer').classList.add('placing');
  $('#placement-hint').hidden = false;
  $('#placement-text').textContent = message;
  viewer.onSphereClick = onClick;
}

function cancelPlacement() {
  $('#viewer').classList.remove('placing');
  $('#placement-hint').hidden = true;
  viewer.onSphereClick = null;
  renderHotspots(); // drop any temporary markers
}

function openDialog(dlg) {
  return new Promise((resolve) => {
    dlg.addEventListener('close', () => resolve(dlg.returnValue), { once: true });
    dlg.showModal();
  });
}

function fillLinkTargets(selected) {
  const select = $('#link-target');
  select.replaceChildren();
  for (const s of tour.scenes) {
    if (s.id === currentSceneId) continue;
    const opt = document.createElement('option');
    opt.value = s.id;
    opt.textContent = s.name;
    opt.selected = s.id === selected;
    select.appendChild(opt);
  }
  return select.options.length > 0;
}

async function addLinkHotspot(pos) {
  const scene = currentScene();
  if (!scene) return;
  if (!fillLinkTargets()) {
    alert('Add at least one more room to link to.');
    return;
  }
  $('#link-delete').hidden = true;
  if (await openDialog($('#dlg-link')) !== 'ok') return;
  scene.hotspots.push({
    id: uid(), type: 'link', lon: pos.lon, lat: pos.lat,
    targetSceneId: $('#link-target').value,
  });
  persist();
  renderHotspots();
}

async function editLinkHotspot(scene, hotspot) {
  if (!fillLinkTargets(hotspot.targetSceneId)) return;
  $('#link-delete').hidden = false;
  const result = await openDialog($('#dlg-link'));
  if (result === 'delete') {
    scene.hotspots = scene.hotspots.filter((h) => h.id !== hotspot.id);
  } else if (result === 'ok') {
    hotspot.targetSceneId = $('#link-target').value;
  } else {
    return;
  }
  persist();
  renderHotspots();
}

async function addInfoHotspot(pos) {
  const scene = currentScene();
  if (!scene) return;
  $('#note-title').value = '';
  $('#note-text').value = '';
  $('#note-delete').hidden = true;
  if (await openDialog($('#dlg-note')) !== 'ok') return;
  scene.hotspots.push({
    id: uid(), type: 'info', lon: pos.lon, lat: pos.lat,
    title: $('#note-title').value.trim() || 'Note',
    text: $('#note-text').value.trim(),
  });
  persist();
  renderHotspots();
}

async function editInfoHotspot(scene, hotspot) {
  $('#note-title').value = hotspot.title;
  $('#note-text').value = hotspot.text || '';
  $('#note-delete').hidden = false;
  const result = await openDialog($('#dlg-note'));
  if (result === 'delete') {
    scene.hotspots = scene.hotspots.filter((h) => h.id !== hotspot.id);
  } else if (result === 'ok') {
    hotspot.title = $('#note-title').value.trim() || 'Note';
    hotspot.text = $('#note-text').value.trim();
  } else {
    return;
  }
  persist();
  renderHotspots();
}

/* ---------- Measuring ---------- */

async function ensureCameraHeight(scene) {
  if (scene.cameraHeight) return true;
  $('#height-input').value = DEFAULT_CAMERA_HEIGHT.toFixed(2);
  if (await openDialog($('#dlg-height')) !== 'ok') return false;
  const h = parseFloat($('#height-input').value);
  if (!(h > 0.3 && h < 3.5)) return false;
  scene.cameraHeight = h;
  persist();
  return true;
}

async function startMeasure() {
  const scene = currentScene();
  if (!scene) return;
  if (!(await ensureCameraHeight(scene))) return;

  let first = null;
  startPlacement('Measure: click a point on the floor', (pos) => {
    if (!first) {
      if (!isFloorPoint(pos)) {
        $('#placement-text').textContent = 'That point is above the horizon — start on the floor';
        return;
      }
      first = pos;
      renderHotspots([{ ...pos, type: 'info', label: 'A' }]); // temporary marker
      $('#placement-text').textContent =
        'Now click a second floor point (distance) or a point straight above the first (height)';
    } else {
      scene.measurements.push({ id: uid(), a: first, b: pos });
      cancelPlacement();
      persist();
      renderMeasurements();
    }
  });
}

/* ---------- Capture ---------- */

async function captureRoom() {
  const blob = await capture.open();
  if (!blob) return;
  const n = tour.scenes.filter((s) => s.name.startsWith('Captured room')).length + 1;
  await addScene(makeScene(`Captured room ${n}`, blob));
}

/* ---------- Mode / top bar ---------- */

function setMode(next) {
  mode = next;
  document.body.classList.toggle('view-mode', mode === 'view');
  $('#mode-edit').classList.toggle('active', mode === 'edit');
  $('#mode-view').classList.toggle('active', mode === 'view');
  cancelPlacement();
}

async function loadTourObject(next) {
  cancelPlacement();
  tour = next;
  currentSceneId = null;
  persist();
  renderAll();
  if (tour.startSceneId) {
    await showScene(tour.startSceneId);
  } else {
    viewer.clearPanorama();
  }
}

function wireUi() {
  $('#mode-edit').addEventListener('click', () => setMode('edit'));
  $('#mode-view').addEventListener('click', () => setMode('view'));

  $('#tour-name').addEventListener('change', (e) => {
    tour.name = e.target.value.trim() || 'Untitled tour';
    e.target.value = tour.name;
    persist();
  });

  const pickRooms = () => $('#file-rooms').click();
  $('#btn-add-rooms').addEventListener('click', pickRooms);
  $('#btn-empty-add').addEventListener('click', pickRooms);
  $('#file-rooms').addEventListener('change', (e) => {
    addSceneFiles(e.target.files);
    e.target.value = '';
  });

  $('#btn-capture').addEventListener('click', captureRoom);
  $('#btn-empty-capture').addEventListener('click', captureRoom);

  const loadDemo = async () => loadTourObject(await createDemoTour());
  $('#btn-demo').addEventListener('click', loadDemo);
  $('#btn-empty-demo').addEventListener('click', loadDemo);

  $('#btn-new').addEventListener('click', async () => {
    if (tour.scenes.length && !confirm('Start a new tour? The current tour is discarded (export it first to keep it).')) return;
    await clearTour().catch(console.error);
    loadTourObject({ id: uid(), name: 'Untitled tour', startSceneId: null, scenes: [] });
  });

  $('#btn-share').addEventListener('click', () => {
    if (!tour.scenes.length) {
      alert('Nothing to share yet — add some rooms first.');
      return;
    }
    exportProjectLink(tour).catch((err) => alert(`Share failed: ${err.message}`));
  });

  $('#btn-export').addEventListener('click', () => {
    if (!tour.scenes.length) {
      alert('Nothing to export yet — add some rooms first.');
      return;
    }
    exportTour(tour).catch((err) => alert(`Export failed: ${err.message}`));
  });

  $('#btn-import').addEventListener('click', () => $('#file-import').click());
  $('#file-import').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    e.target.value = '';
    if (!file) return;
    try {
      await loadTourObject(await importTour(file));
    } catch (err) {
      alert(`Import failed: ${err.message}`);
    }
  });

  $('#btn-fullscreen').addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen();
  });

  $('#btn-add-link').addEventListener('click', () => {
    if (!currentScene()) return;
    startPlacement('Click where the link to another room should be', (pos) => {
      cancelPlacement();
      addLinkHotspot(pos);
    });
  });
  $('#btn-add-note').addEventListener('click', () => {
    if (!currentScene()) return;
    startPlacement('Click where the note should be pinned', (pos) => {
      cancelPlacement();
      addInfoHotspot(pos);
    });
  });
  $('#btn-measure').addEventListener('click', startMeasure);
  $('#btn-set-view').addEventListener('click', () => {
    const scene = currentScene();
    if (!scene) return;
    scene.view = viewer.getView();
    persist();
  });
  $('#btn-cancel-place').addEventListener('click', cancelPlacement);

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') cancelPlacement();
  });
}

/* ---------- Boot ---------- */

async function boot() {
  wireUi();
  try {
    const saved = await loadTour();
    if (saved?.scenes?.length) {
      tour = saved;
    }
  } catch (err) {
    console.error('Could not restore saved tour', err);
  }
  renderAll();
  if (tour.startSceneId) await showScene(tour.startSceneId);
}

boot();
