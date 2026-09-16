/**
 * Dictation for the logbook fields.
 *
 * What "on device" actually means here matters, so the app is explicit about
 * it rather than hiding it behind a microphone icon:
 *
 *   - On-device: Chromium's on-device Web Speech mode. `available()` reports
 *     whether a local language pack exists, `install()` downloads one, and
 *     `processLocally = true` then keeps the audio on the phone. This is the
 *     only mode that works with no network and sends nothing anywhere.
 *   - Cloud: the classic Web Speech API. Chrome streams the audio to Google's
 *     servers; Safari uses Apple's service. It needs a connection and it
 *     leaves the device, so the app never silently falls back to it — the
 *     "Nur Diktat auf dem Gerät" setting (on by default) has to be turned off
 *     first, and the UI labels the mode on every button.
 *
 * Typing always works, in every browser, with no permission prompt.
 *
 * Reference: https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition/available_static
 */

const Recognition = window.SpeechRecognition ?? window.webkitSpeechRecognition ?? null;

export const isSupported = () => Recognition !== null;

/** True when this build exposes the on-device extensions at all. */
const hasOnDeviceApi = () =>
  Recognition !== null &&
  typeof Recognition.available === 'function' &&
  typeof Recognition.install === 'function';

/**
 * `available()` is implemented by the browser's speech service, which can be
 * slow to start or absent altogether — in some builds the promise simply never
 * settles. Nothing in the UI may wait on it forever, so every call is capped.
 */
function withTimeout(promise, ms, fallback) {
  return Promise.race([
    promise,
    new Promise((resolve) => setTimeout(() => resolve(fallback), ms)),
  ]);
}

/**
 * Crash guard.
 *
 * On some builds — headless Chromium without a speech service is one we hit
 * while testing — calling `available()` takes the whole renderer down. A tab
 * that dies cannot catch anything, so instead a flag is written synchronously
 * before the call and cleared after it: if it is still set on the next load,
 * the previous attempt never returned and we stop asking. The user can clear
 * this from the settings page if it was a false alarm (force-quitting the app
 * mid-probe looks the same from here).
 */
const PROBE_FLAG = 'qrlog:stt-probe-crashed';

export function probeIsBlocked() {
  try {
    return localStorage.getItem(PROBE_FLAG) === '1';
  } catch {
    return false;
  }
}

export function resetProbeBlock() {
  try {
    localStorage.removeItem(PROBE_FLAG);
  } catch {
    /* Private mode without storage — nothing to reset. */
  }
}

function markProbeInFlight(inFlight) {
  try {
    if (inFlight) localStorage.setItem(PROBE_FLAG, '1');
    else localStorage.removeItem(PROBE_FLAG);
  } catch {
    /* Without storage we simply lose the guard. */
  }
}

/**
 * What dictation can do right now.
 * `mode` is what a click on the microphone would use: 'on-device', 'cloud'
 * or 'none'. `state` mirrors the browser's on-device language pack status.
 */
export async function probe(lang, { offlineOnly = true } = {}) {
  if (!isSupported()) {
    return { mode: 'none', state: 'unsupported', canInstall: false };
  }
  // The guard covers the whole speech stack, not just the on-device probe:
  // whatever took the renderer down last time, we do not poke it again.
  if (probeIsBlocked()) {
    return { mode: 'none', state: 'blocked', canInstall: false };
  }
  let state = 'unsupported';
  if (hasOnDeviceApi()) {
    markProbeInFlight(true);
    try {
      state = await withTimeout(
        Recognition.available({ langs: [lang], processLocally: true }),
        2500,
        'unavailable'
      );
    } catch {
      state = 'unavailable';
    } finally {
      markProbeInFlight(false);
    }
  }
  if (state === 'available') return { mode: 'on-device', state, canInstall: false };

  const canInstall = state === 'downloadable' || state === 'downloading';
  if (offlineOnly) return { mode: 'none', state, canInstall };
  return { mode: 'cloud', state, canInstall };
}

/**
 * Ask the browser to download the local language pack. Resolves true when the
 * pack is installed. The download is tens to hundreds of MB and only needs to
 * happen once per device, so it is offered as an explicit button rather than
 * triggered on the first tap of the microphone.
 */
export async function installOnDevice(lang) {
  if (!hasOnDeviceApi()) throw new Error('Dieser Browser kann kein Sprachmodell lokal installieren.');
  return Recognition.install({ langs: [lang], processLocally: true });
}

/**
 * A dictation session bound to one text field.
 *
 * Mobile browsers end recognition on their own after a pause; as long as the
 * user has not pressed stop we restart it, so a technician can think mid
 * sentence without losing the microphone.
 */
export class Dictation {
  constructor({ lang, onDevice, onInterim, onFinal, onEnd, onError }) {
    this.lang = lang;
    this.onDevice = onDevice;
    this.onInterim = onInterim ?? (() => {});
    this.onFinal = onFinal ?? (() => {});
    this.onEnd = onEnd ?? (() => {});
    this.onError = onError ?? (() => {});
    this.recognition = null;
    this.stopping = false;
  }

  start() {
    const recognition = new Recognition();
    recognition.lang = this.lang;
    recognition.continuous = true;
    recognition.interimResults = true;
    if (this.onDevice) recognition.processLocally = true;

    recognition.onresult = (event) => {
      let interim = '';
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const result = event.results[i];
        if (result.isFinal) this.onFinal(result[0].transcript);
        else interim += result[0].transcript;
      }
      this.onInterim(interim);
    };
    recognition.onerror = (event) => {
      // 'no-speech' and 'aborted' are normal parts of a pause; anything else
      // is worth showing the user.
      if (event.error === 'no-speech' || event.error === 'aborted') return;
      this.stopping = true;
      this.onError(event.error);
    };
    recognition.onend = () => {
      if (this.stopping) {
        this.onEnd();
        return;
      }
      try {
        recognition.start();
      } catch {
        this.onEnd();
      }
    };

    // Same crash guard as the probe: starting recognition is the other call
    // that can take a broken speech service — and the tab — down with it.
    markProbeInFlight(true);
    const clearGuard = () => markProbeInFlight(false);
    recognition.addEventListener('start', clearGuard, { once: true });
    setTimeout(clearGuard, 4000);

    this.recognition = recognition;
    this.stopping = false;
    recognition.start();
  }

  stop() {
    this.stopping = true;
    this.recognition?.stop();
  }
}

/** Human-readable label for the badge next to each microphone button. */
export function modeLabel(mode) {
  if (mode === 'on-device') return '🔒 Auf dem Gerät';
  if (mode === 'cloud') return '☁️ Cloud';
  return 'Nicht verfügbar';
}
