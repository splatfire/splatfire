// Minimal view-only runtime embedded into exported "project link" HTML files.
// It rebuilds the same DOM structure index.html uses (so style.css applies)
// and drives a PanoViewer over the inlined tour data.

import { PanoViewer } from 'viewer';
import { measurementLabel } from 'measure';

function dataUrlToBlob(dataUrl) {
  const [head, body] = dataUrl.split(',');
  const mime = head.match(/^data:([^;]+)/)?.[1] ?? 'image/jpeg';
  const bytes = atob(body);
  const arr = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) arr[i] = bytes.charCodeAt(i);
  return new Blob([arr], { type: mime });
}

export async function start(tour) {
  document.body.classList.add('view-mode');
  document.body.innerHTML = `
    <header id="topbar">
      <div class="brand">Splatfire <span>360° Room Tours</span></div>
      <div id="shared-tour-name"></div>
      <div class="topbar-actions">
        <button id="btn-fullscreen" title="Toggle fullscreen">⛶</button>
      </div>
    </header>
    <div id="layout">
      <aside id="sidebar">
        <div class="sidebar-title">Rooms</div>
        <ul id="scene-list"></ul>
      </aside>
      <main id="stage"><div id="viewer"></div></main>
    </div>
    <dialog id="dlg-note-view">
      <form method="dialog">
        <h2 id="note-view-title"></h2>
        <p id="note-view-text"></p>
        <div class="dlg-actions"><button value="ok" class="primary">Close</button></div>
      </form>
    </dialog>`;

  document.getElementById('shared-tour-name').textContent = tour.name;
  document.title = `${tour.name} — Splatfire`;
  document.getElementById('btn-fullscreen').addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen();
  });

  const viewer = new PanoViewer(document.getElementById('viewer'));
  for (const scene of tour.scenes) scene.image = dataUrlToBlob(scene.image);

  let currentId = null;

  function renderList() {
    const ul = document.getElementById('scene-list');
    ul.replaceChildren();
    for (const scene of tour.scenes) {
      const li = document.createElement('li');
      li.classList.toggle('active', scene.id === currentId);
      const name = document.createElement('span');
      name.className = 'scene-name';
      name.textContent = scene.name;
      li.appendChild(name);
      li.addEventListener('click', () => showScene(scene.id));
      ul.appendChild(li);
    }
  }

  async function showScene(id) {
    const scene = tour.scenes.find((s) => s.id === id);
    if (!scene) return;
    currentId = id;
    renderList();
    await viewer.showPanorama(scene.image, scene.view);

    viewer.setHotspots((scene.hotspots ?? []).map((h) => ({
      lon: h.lon,
      lat: h.lat,
      type: h.type,
      label: h.type === 'link'
        ? tour.scenes.find((s) => s.id === h.targetSceneId)?.name ?? ''
        : h.title,
      onClick: () => {
        if (h.type === 'link') {
          showScene(h.targetSceneId);
        } else {
          document.getElementById('note-view-title').textContent = h.title;
          document.getElementById('note-view-text').textContent = h.text || '';
          document.getElementById('dlg-note-view').showModal();
        }
      },
    })));

    viewer.setLines((scene.measurements ?? []).map((m) => ({
      a: m.a,
      b: m.b,
      label: measurementLabel(m, scene.cameraHeight ?? 1.4),
    })));
  }

  if (tour.startSceneId) await showScene(tour.startSceneId);
}
