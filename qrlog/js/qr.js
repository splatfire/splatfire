/**
 * QR code generation.
 *
 * The code carries the URL of this app plus the asset id, e.g.
 * https://example.ch/qrlog/#/a/k3f9x2qw81 — so a phone's built-in camera
 * opens the logbook directly, and the in-app scanner works from the same
 * label without a network connection.
 */

import qrcode from '../vendor/qrcode.js';

/** Base URL of the app, without any hash route. */
export function appBaseUrl() {
  return location.href.split('#')[0];
}

export function assetUrl(id) {
  return `${appBaseUrl()}#/a/${id}`;
}

/**
 * Render `text` as an SVG QR code.
 *
 * Type 0 lets the library pick the smallest version that fits. Error
 * correction M is the usual choice for printed labels: it survives a scuffed
 * or partly dirty sticker without blowing up the module count.
 */
export function qrSvg(text, { margin = 2, ecc = 'M' } = {}) {
  const qr = qrcode(0, ecc);
  qr.addData(text, 'Byte');
  qr.make();

  const count = qr.getModuleCount();
  const size = count + margin * 2;
  let path = '';
  for (let row = 0; row < count; row++) {
    for (let col = 0; col < count; col++) {
      if (qr.isDark(row, col)) path += `M${col + margin} ${row + margin}h1v1h-1z`;
    }
  }
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" ` +
    `shape-rendering="crispEdges" role="img" aria-label="QR-Code">` +
    `<rect width="${size}" height="${size}" fill="#fff"/>` +
    `<path d="${path}" fill="#000"/></svg>`
  );
}

/** The scanned text back to an asset id, or null if it is not one of ours. */
export function idFromScan(text) {
  if (!text) return null;
  const hash = text.includes('#') ? text.slice(text.indexOf('#')) : text;
  const match = hash.match(/(?:^|#)\/?a\/([0-9a-z]{6,24})$/i);
  if (match) return match[1].toLowerCase();
  // A bare id, e.g. a code written by hand or produced by another tool.
  return /^[0-9a-z]{6,24}$/i.test(text.trim()) ? text.trim().toLowerCase() : null;
}

/** A PNG data URL of the QR code, for download and for the print sheet. */
export function qrPngDataUrl(text, pixels = 1024) {
  return new Promise((resolve, reject) => {
    const svg = qrSvg(text);
    const img = new Image();
    const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }));
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = pixels;
      const ctx = canvas.getContext('2d');
      ctx.imageSmoothingEnabled = false;
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, pixels, pixels);
      ctx.drawImage(img, 0, 0, pixels, pixels);
      URL.revokeObjectURL(url);
      resolve(canvas.toDataURL('image/png'));
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error('QR-Code konnte nicht gerendert werden.'));
    };
    img.src = url;
  });
}
