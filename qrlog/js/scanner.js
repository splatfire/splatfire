/**
 * Camera QR scanning, entirely on the device.
 *
 * Chrome and most Android browsers ship a native `BarcodeDetector`, which is
 * faster and uses less battery than decoding in JS. Safari/iOS does not, so
 * the vendored jsQR decoder is loaded lazily as a fallback — lazily, because
 * it is 250 KB that Chrome users never need to parse.
 */

let jsQR = null;

async function loadJsQr() {
  jsQR ??= (await import('../vendor/jsQR.js')).default;
  return jsQR;
}

async function makeDetector() {
  if (!('BarcodeDetector' in window)) return null;
  try {
    const formats = await window.BarcodeDetector.getSupportedFormats();
    if (!formats.includes('qr_code')) return null;
    return new window.BarcodeDetector({ formats: ['qr_code'] });
  } catch {
    return null;
  }
}

export class Scanner {
  constructor(videoEl) {
    this.video = videoEl;
    this.stream = null;
    this.raf = 0;
    this.canvas = document.createElement('canvas');
  }

  /**
   * Open the rear camera and call `onResult(text)` on the first decode.
   * Throws if the camera is unavailable or permission is denied.
   */
  async start(onResult) {
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: 'environment' } },
      audio: false,
    });
    this.video.srcObject = this.stream;
    this.video.setAttribute('playsinline', '');
    await this.video.play();

    const detector = await makeDetector();
    if (!detector) await loadJsQr();

    let done = false;
    const tick = async () => {
      if (done || !this.stream) return;
      const text = await this.decodeFrame(detector);
      if (text) {
        done = true;
        this.stop();
        onResult(text);
        return;
      }
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  async decodeFrame(detector) {
    const { video } = this;
    if (!video.videoWidth) return null;
    if (detector) {
      try {
        const [first] = await detector.detect(video);
        return first?.rawValue ?? null;
      } catch {
        return null;
      }
    }
    // jsQR path: downscale to keep per-frame work bounded on older phones.
    const scale = Math.min(1, 640 / video.videoWidth);
    const w = (this.canvas.width = Math.round(video.videoWidth * scale));
    const h = (this.canvas.height = Math.round(video.videoHeight * scale));
    const ctx = this.canvas.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(video, 0, 0, w, h);
    const image = ctx.getImageData(0, 0, w, h);
    const result = jsQR(image.data, w, h, { inversionAttempts: 'dontInvert' });
    return result?.data ?? null;
  }

  stop() {
    cancelAnimationFrame(this.raf);
    this.raf = 0;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
    this.video.srcObject = null;
  }
}

/** Decode a QR code out of a still image file, for phones without a usable camera stream. */
export async function decodeImageFile(file) {
  const bitmap = await createImageBitmap(file);
  const canvas = document.createElement('canvas');
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(bitmap, 0, 0);

  const detector = await makeDetector();
  if (detector) {
    const [first] = await detector.detect(canvas);
    if (first) return first.rawValue;
  }
  await loadJsQr();
  const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
  return jsQR(image.data, canvas.width, canvas.height)?.data ?? null;
}
