# QR-Logbuch

Label an installation (Anlage) with a QR code, scan it on site, and keep every
service visit in a logbook. The point is the handover: the technician who opens
the panel in a year should read exactly what the last one did, in their words.

The UI is German, because the people holding the phone in the plant room are.
Code and comments are English, like the rest of this repo.

## What it does

- **QR code per Anlage** — generated automatically, no code entry anywhere. The
  code holds this app's URL plus a random 50-bit id, so a phone's own camera
  opens the logbook and the id can't be guessed from a neighbouring label.
- **Anlage sheet** — type, location, manufacturer, model, serial, commissioning
  date, service interval, free notes, photos.
- **Logbook entry per visit** — the lead field is *"Was wurde heute gemacht?"*,
  plus findings, material used, next service date and photos. Newest first.
- **Dictation** — speak the entry instead of typing it with cold hands, field by
  field, or in one go with the ramble bar below. See the honest version of
  "offline" further down.
- **In-app scanner** — native `BarcodeDetector` where the browser has one,
  the vendored jsQR decoder otherwise (iOS). Also reads a QR out of a photo.
- **Blank labels** — print a sheet of unassigned codes, stick one on, scan it,
  and the app offers to create the Anlage right there.
- **Offline** — service worker caches the app; data lives in IndexedDB. A cellar
  with no signal is the normal case, not the edge case.
- **Export / import** — one JSON file with photos inlined, to move data to
  another device or keep a backup.

## The ramble bar

A technician does not dictate field by field. The bar pinned to the bottom of
the entry form takes one long take — *"Also heute Jahreswartung gemacht, Filter
gewechselt, Soledruck war eins komma vier bar, die Umwälzpumpe läuft unruhig,
verbaut habe ich einen Solefilter, nächster Service in einem Jahr"* — and
proposes where each sentence belongs:

| Field | Gets |
| --- | --- |
| Ausgeführte Arbeiten | everything not claimed by another field |
| Befund / Zustand | sentences about condition: *unruhig, undicht, beobachten, muss ersetzt* |
| Verbautes Material | *verbaut, eingebaut, Ersatzteil, Stück* |
| Nächster Service | a date, but only where the sentence is about coming back |
| Art, Datum | *Wartung / Störung / Reparatur …*, and *gestern / vorgestern* |

It also rewrites spoken decimals, so *"eins komma vier bar"* is stored as
`1.4 bar` and stays searchable.

**This is a rule-based German parser, not a language model.** It runs entirely
on the device, which is the whole point — but it gets unusual phrasing wrong.
So it never writes into the form by itself: it shows what it proposes with a
checkbox per field, and *"Alles in «Arbeiten»"* dumps the raw transcript into
one field when the routing guessed badly. Nothing spoken is ever discarded.

The rules live in [`js/parse.js`](js/parse.js) as pure functions, with tests:

```sh
node --test qrlog/js/parse.test.mjs
```

Extending it means adding cue words to `FIELD_CUES` / `KIND_CUES` and a test
case. A real language model would handle phrasing this cannot — but in a static
app that would mean an API key in the browser, so it needs a backend first.

## How offline the dictation really is

Three different things get called "speech to text in the browser", and only one
of them is actually on-device:

| Mode | Audio leaves the device | Works with no signal |
| --- | --- | --- |
| On-device Web Speech (`processLocally = true`) | no | yes, once the language pack is installed |
| Classic Web Speech API | yes — Chrome to Google, Safari to Apple | no |
| Typing | no | yes |

The app prefers the first, and **never silently falls back to the second**. The
*"Nur Diktat auf dem Gerät zulassen"* setting is on by default; with it on, the
microphone refuses rather than sending audio anywhere. Every recording session
also shows which mode it is using. The on-device language pack is a one-time
download the user starts explicitly in the settings.

On-device mode needs a Chromium that ships `SpeechRecognition.available()` /
`install()`. Where that is missing, dictation is simply unavailable unless the
user opts in to cloud recognition — see
[MDN](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition/available_static).

The speech stack is only ever touched when the user asks for it (tapping a
microphone, or *"Diktat prüfen"* in the settings). Some browser builds crash the
whole tab on the first call — headless Chromium without a speech service does —
and a crashed tab can't catch anything, so a flag is written before the call and
cleared after it. If it's still set on the next load, the app stops asking and
offers a reset in the settings.

## Data, and what this version is not

Everything is local to the device that typed it. There is no account, no server,
no sync: two phones that scan the same label see two different logbooks until
someone exports and imports. That is the honest limit of a static app, and the
first thing a real deployment would need to change.

## Running

Static — serve the repo root:

```sh
npx serve .          # then open /qrlog/
python3 -m http.server 8000
```

A real device needs HTTPS (or localhost) for the camera, the microphone and the
service worker.

## Printing labels

*Etiketten drucken* lays out a printable sheet. Print on weatherproof adhesive
labels, at least 25 mm square — smaller than that and a phone camera struggles
in bad light. A boiler-room label also has to survive heat, condensation and
cleaning agents for the life of the installation; that is a materials decision,
not a software one.

## Third-party code

- [`vendor/qrcode.js`](vendor/qrcode.js) — QR encoder by Kazuhiko Arase, MIT.
- [`vendor/jsQR.js`](vendor/jsQR.js) — QR decoder, Apache-2.0.

Both are vendored rather than loaded from a CDN, because the app has to work
with no network at all. Each carries its licence next to it.
