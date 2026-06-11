// In-browser room capture: the user stands in the middle of the room and
// snaps overlapping photos while turning in a circle. Frames are placed on
// an equirectangular canvas by their yaw (device compass when available,
// otherwise a fixed step per snap) and feathered together.
//
// A dedicated 360° camera gives better panoramas — this exists so a room can
// be captured with nothing but a phone or laptop.

const HFOV = 62; // assumed horizontal field of view of the device camera, degrees
const PANO_W = 4096;
const PANO_H = 2048;
const SECTORS = 12;

export class RoomCapture {
  constructor() {
    this.overlay = document.getElementById('capture-overlay');
    this.video = document.getElementById('capture-video');
    this.msg = document.getElementById('capture-msg');
    this.progress = document.getElementById('capture-progress');
    this.snapBtn = document.getElementById('capture-snap');
    this.doneBtn = document.getElementById('capture-done');
    this.cancelBtn = document.getElementById('capture-cancel');

    this.snapBtn.addEventListener('click', () => this._snap());
    this.doneBtn.addEventListener('click', () => this._finish(false));
    this.cancelBtn.addEventListener('click', () => this._finish(true));

    this._onOrientation = (e) => {
      if (e.alpha == null) return;
      this.hasGyro = true;
      this.yaw = 360 - e.alpha; // alpha grows counter-clockwise
      this.pitch = (e.beta ?? 90) - 90;
    };
  }

  /** Runs the capture flow; resolves with a panorama Blob, or null if cancelled. */
  async open() {
    if (this._resolve) return null; // already capturing
    this.frames = [];
    this.hasGyro = false;
    this.yaw = 0;
    this.pitch = 0;

    try {
      // Prefer the rear camera; fall back to whatever camera exists
      // (laptops and desktops usually only have a front-facing one).
      this.stream = await navigator.mediaDevices
        .getUserMedia({ video: { facingMode: { exact: 'environment' }, width: { ideal: 1920 } } })
        .catch(() => navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1920 } } }));
    } catch (err) {
      alert(`Camera not available: ${err.message}`);
      return null;
    }
    this.video.srcObject = this.stream;

    try {
      // iOS requires an explicit permission request for orientation events.
      await DeviceOrientationEvent?.requestPermission?.();
    } catch { /* denied — fall back to fixed-step mode */ }
    window.removeEventListener('deviceorientation', this._onOrientation);
    window.addEventListener('deviceorientation', this._onOrientation);

    this.overlay.hidden = false;
    this._renderProgress();
    this.msg.textContent =
      'Stand in the middle of the room. Snap a photo, turn a little, snap again — all the way around.';

    return new Promise((resolve) => { this._resolve = resolve; });
  }

  _snap() {
    if (!this.video.videoWidth) return;
    const canvas = document.createElement('canvas');
    canvas.width = this.video.videoWidth;
    canvas.height = this.video.videoHeight;
    canvas.getContext('2d').drawImage(this.video, 0, 0);

    // Without a gyro, assume the user turns ~80% of the field of view per snap.
    const yaw = this.hasGyro ? this.yaw : this.frames.length * HFOV * 0.8;
    const pitch = this.hasGyro ? this.pitch : 0;
    this.frames.push({ canvas, yaw: ((yaw % 360) + 360) % 360, pitch });
    this._renderProgress();
  }

  _renderProgress() {
    this.progress.replaceChildren();
    for (let i = 0; i < SECTORS; i++) {
      const covered = this.frames.some((f) => {
        const center = (i + 0.5) * (360 / SECTORS);
        const diff = Math.abs(((f.yaw - center + 540) % 360) - 180);
        return diff < HFOV / 2;
      });
      const seg = document.createElement('span');
      seg.classList.toggle('covered', covered);
      this.progress.appendChild(seg);
    }
    this.doneBtn.disabled = this.frames.length === 0;
    if (this.frames.length) {
      this.msg.textContent = `${this.frames.length} photo${this.frames.length > 1 ? 's' : ''} — keep turning until the ring is full, then press Done.`;
    }
  }

  async _finish(cancelled) {
    const frames = this.frames;
    const resolve = this._resolve;
    this._resolve = null;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.video.srcObject = null;
    window.removeEventListener('deviceorientation', this._onOrientation);
    this.overlay.hidden = true;

    if (!resolve) return;
    resolve(cancelled || !frames.length ? null : await stitch(frames));
  }
}

function featheredFrame(frame, width, height) {
  const c = document.createElement('canvas');
  c.width = width;
  c.height = height;
  const ctx = c.getContext('2d');
  ctx.drawImage(frame.canvas, 0, 0, width, height);
  const fade = width * 0.12;
  const grad = ctx.createLinearGradient(0, 0, width, 0);
  grad.addColorStop(0, 'rgba(0,0,0,0)');
  grad.addColorStop(fade / width, 'rgba(0,0,0,1)');
  grad.addColorStop(1 - fade / width, 'rgba(0,0,0,1)');
  grad.addColorStop(1, 'rgba(0,0,0,0)');
  ctx.globalCompositeOperation = 'destination-in';
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, width, height);
  return c;
}

function stitch(frames) {
  const pano = document.createElement('canvas');
  pano.width = PANO_W;
  pano.height = PANO_H;
  const ctx = pano.getContext('2d');
  ctx.fillStyle = '#23262c';
  ctx.fillRect(0, 0, PANO_W, PANO_H);

  // Degrees map to pixels isotropically (W/360 === H/180), so one scale fits both axes.
  const pxPerDeg = PANO_W / 360;
  for (const frame of [...frames].sort((x, y) => x.yaw - y.yaw)) {
    const w = HFOV * pxPerDeg;
    const h = w * (frame.canvas.height / frame.canvas.width);
    const x = frame.yaw * pxPerDeg - w / 2;
    const y = PANO_H / 2 - frame.pitch * pxPerDeg - h / 2;
    const strip = featheredFrame(frame, w, h);
    // Draw twice more, shifted by ±360°, so strips wrap across the seam.
    for (const dx of [-PANO_W, 0, PANO_W]) {
      ctx.drawImage(strip, x + dx, y);
    }
  }
  return new Promise((resolve) => pano.toBlob(resolve, 'image/jpeg', 0.85));
}
