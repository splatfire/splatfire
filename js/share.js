// Builds the "project link" export: one self-contained HTML file with the
// viewer code, styles, and the whole tour (images inlined as data URLs)
// embedded. Anyone can open it in a browser — no server, no install.

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result);
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Could not load ${url}`);
  return res.text();
}

const asModuleUrl = (src) => `data:text/javascript;charset=utf-8,${encodeURIComponent(src)}`;

export async function exportProjectLink(tour) {
  const [threeSrc, viewerSrc, measureSrc, shareViewerSrc, css] = await Promise.all([
    fetchText('vendor/three.module.js'),
    fetchText('js/viewer.js'),
    fetchText('js/measure.js'),
    fetchText('js/share-viewer.js'),
    fetchText('css/style.css'),
  ]);

  const scenes = await Promise.all(
    tour.scenes.map(async (s) => ({ ...s, image: await blobToDataUrl(s.image) })),
  );
  const data = { ...tour, scenes };

  const importMap = JSON.stringify({
    imports: {
      three: asModuleUrl(threeSrc),
      viewer: asModuleUrl(viewerSrc),
      measure: asModuleUrl(measureSrc),
      'share-viewer': asModuleUrl(shareViewerSrc),
    },
  });

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>${escapeHtml(tour.name)} — Splatfire</title>
<style>${css}</style>
<script type="importmap">${importMap}<\/script>
</head>
<body>
<script type="module">
import { start } from 'share-viewer';
start(${JSON.stringify(data).replace(/</g, '\\u003c')});
<\/script>
</body>
</html>`;

  const blob = new Blob([html], { type: 'text/html' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `${(tour.name || 'tour').replace(/[^\w\- ]+/g, '').trim() || 'tour'}.html`;
  a.click();
  URL.revokeObjectURL(a.href);
}

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}
