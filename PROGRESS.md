STATUS: DONE

# EightCount (iOS dance-practice app) — progress

App lives in `eightcount/`. Generate the Xcode project with `xcodegen generate` in that folder
(full instructions in `eightcount/README.md`).

## Done (everything in "Scope for this session")
- [x] Project skeleton: `eightcount/project.yml` (XcodeGen), Info.plist, asset catalog + app icon
- [x] SwiftData models: Project, CountNote, PoseSnapshot
- [x] Video import from Photos (PhotosPicker) and Files (fileImporter), copied into Application Support/Videos
- [x] Projects: list, create, rename, delete (with confirmation), add/replace video
- [x] Playback: mirror, 0.25/0.5/0.75/1/2x with pitch correction, A-B loop, slider + fine-scrub strip + frame steps, screen stays awake while playing
- [x] 8-count grid: BPM entry + tap tempo (speed-corrected), count-1 offset, jump to 8-count, loop one 8-count
- [x] Notes per 8-count (text, feet, arms, facing, lyric cue) + pose snapshots (AVAssetImageGenerator)
- [x] Export/import of notes + snapshots as `.eightcount.json` via share sheet / file importer
- [x] Independent review pass of the whole codebase; fixes applied
- [x] README: setup on Mac, free vs paid account, permissions, Check on Mac, Decisions, Next steps

## Session 2 scope (done)
User asked for (subagents must use model "sonnet" to save tokens):
1. Record yourself (front camera, no mic) while the tutorial plays; live side-by-side or ghost overlay.
2. Compare screen: landscape = you LEFT / tutorial RIGHT, portrait = you TOP / tutorial BOTTOM; synced, audio from tutorial.
3. On-device AI analysis (Vision body pose + Apple Foundation Models tips; user has iPhone 15 Pro+).
4. Liquid Glass (iOS 26+ APIs, guarded so iOS 17 still works).

- [x] Foundation (me): Take model, AnalysisReport, TakeTiming, TakeStore, OrientationLock, Glass styling, Info.plist camera key
- [x] Recording (sonnet agent): Recording/ (CameraRecorder, CameraPreviewView, RecordView)
- [x] Compare (sonnet agent): Compare/ (SyncedPlayback, CompareView, TakesListView)
- [x] Analysis (sonnet agent): Analysis/ (PoseExtractor, PoseComparer, CoachWriter, AnalysisView)
- [x] Integration in ProjectDetailView (record button, My Takes, compare cover)
- [x] Review (sonnet agent) + README update (features, permissions, decisions, Check on Mac D)

## Session 3 (in progress): get it building with Xcode 27
- The cloud session can't reach the user's Mac. Instead: GitHub Actions compile check
  `.github/workflows/eightcount-ios-build.yml` (runners `xcode-27` [preview] and `macos-26`),
  unsigned `xcodebuild build -destination generic/platform=iOS`. Fix errors until green.
- Added `eightcount/setup-mac.sh` (one-command local setup) and `eightcount/.gitignore`.
- Fixed README: decision bullets had been pasted into the feature list.

- RESULT run 38425842568: Xcode 27 (27A266a, iPhoneOS27.0 SDK) and Xcode 26: BUILD SUCCEEDED, 0 errors.
  Only Sendable warnings in CameraRecorder -> silenced with `@preconcurrency import AVFoundation`.
- Added CI job "Launch in Simulator (Xcode 27)": boots an iPhone simulator, installs, launches,
  checks the process is alive after 12 s, uploads launch.png.

- Added UI test target `EightCountUITests` + Debug-only `App/DebugSeed.swift` (`-seedDemo`), CI job
  "UI test in Simulator (Xcode 27)" with ffmpeg test video. Run 38430578163: ALL GREEN
  (build Xcode 27, build Xcode 26, UI test 12 steps, no crash). Screenshots checked: practice, loop,
  notes, takes, compare portrait + landscape (YOU left / TUTORIAL right), analysis error for no-person video.
- First UI-test attempt failed only because the XCTest runner didn't bootstrap on CI -> fixed by
  booting the simulator first + build-for-testing + one retry.

- `setup-mac.sh --install` now builds + signs (auto-detects Team ID, -allowProvisioningUpdates),
  installs and launches on the USB iPhone via `xcrun devicectl`; stops with clear instructions for
  Apple-ID sign-in / Trust / Developer Mode. CI job "setup-mac.sh (Xcode 27)" verifies it on macOS
  (green, run 38443989478). Added eightcount/CLAUDE.md for a local Claude Code session.
- This cloud session can't reach the Mac: the device install itself is run by the user.
- 2026-10-13: user ran `setup-mac.sh --install` on their Mac (Xcode 27.0, free Apple ID).
  Signed, installed and RUNNING on their iPhone after trusting the developer certificate. ✅

- UI cleanup round (user feedback "janky"): new Design/Components.swift (round buttons, PillPicker, cards);
  practice controls, 8-count rows, New Project sheet, project list (thumbnails), compare + record restyled.
- User feedback round 2: Dynamic Island overlap fixed (compare/record controls respect safe area);
  coach mode (tap an issue → pause at that moment, skeletons over both videos with the problem limb in
  red, caption card with ‹ › and Replay, red issue dots on the timeline, "N things to fix" button);
  ghost mode with auto-alignment to your body (+ drag/pinch); clearer analysis results ("Show me on the
  video", numbered Top fixes). CI green incl. UI test with ghost/coach screenshots (run 38460974176).
- Not verifiable in CI: skeleton drawing on a real person (test video has no person).

- Updates without cable (user chose "Wi-Fi now, TestFlight later"): `setup-mac.sh --update` (git pull +
  install, works over Wi-Fi) and `--shortcut` (Desktop "Update EightCount.command"); Team/bundle ID now in
  gitignored `eightcount/.eightcount-local` (script migrates the old project.yml edit). TestFlight workflow
  `.github/workflows/eightcount-testflight.yml` skips until secrets ASC_KEY_ID / ASC_ISSUER_ID /
  ASC_KEY_P8_BASE64 / APPLE_TEAM_ID exist (needs paid membership; untested until then).
- Analysis sheet: full height + fixed header (iOS 26 half-height sheets float with inset corners → looked misaligned).

- Save to Photos (TikTok): Services/TakeExporter.swift + Compare/ExportTakeSheet.swift — me with the song
  (synced tutorial audio, real tempo, optional mirror), me + tutorial 9:16, original. Recording now explicit
  1080p. UI test exports to the simulator's Photos ("Saved to Photos") — green (run for b8c9e66).
- Fine-scrub ruler direction fixed (drag left = forward, ticks follow finger).

- Instant replay: after a recording is saved, RecordView switches straight to CompareView(autoPlay) inside
  the same cover, with "Record again". Compare autoplays on open and when a speed is picked.
  Countdown beeps (Resources/Sounds/countdown-tick.wav ×3 + countdown-go.wav at music start, self-made, not
  TikTok's file), toggle "Countdown sound". CI green incl. UI test asserting autoplay (run for 9d137e8).
  Not testable in CI: camera recording → instant replay, and the beeps (need a real iPhone).

- Decision (user): stay on the FREE Apple ID for now (no paid membership, no TestFlight/App Store).
  Updates via Desktop "Update EightCount" (Wi-Fi), at least every 7 days. TestFlight workflow stays dormant.

- Auto-refresh (user chose it over AltStore): `setup-mac.sh --auto-refresh` installs LaunchAgent
  io.github.splatfire.eightcount.refresh (every 3 h) running `setup-mac.sh --refresh`: acts ~once/day
  (state in eightcount/.refresh-state), git pull, deletes cached signing profiles for the app that expire
  within 4 days (to force a fresh 7-day profile — UNVERIFIED whether Xcode then issues a new one),
  builds, installs over Wi-Fi, notifications via osascript. Needs a week of real use to confirm.

- Apple Watch remote (user picked "remote control" only; watch: Series 6–8/SE 2/Ultra 1 → watchOS 10):
  target EightCountWatch (single-target watchOS app embedded in the iOS app), Shared/WatchProtocol.swift
  (RemoteCommand/RemoteState dictionaries), iPhone side Services/WatchRemote.swift (WCSession, handler
  stack, 0.5 s change-push) + WatchRemoteHandlers.swift (practice, compare, recording = blocked).
  Bundle ID now comes from EC_APP_BUNDLE_ID (watch = +.watchkitapp); setup-mac.sh passes EC_APP_BUNDLE_ID
  and downloads the watchOS platform if missing. Not tried on a real watch (free-account signing!).

- Practice tools from the dancer research (user: "do as you just suggested"): Practice/PracticeCoach.swift
  (build-up + speed ladder, advance on PlayerController.loopWraps), Practice/CountCues.swift (count-in via
  PlayerController.countIn hook, beat click / spoken counts scheduled on the audio clock with
  AVAudioPlayerNode, spoken move names via AVSpeechSynthesizer, fade per loop run), memory-test cover,
  next-move hint, pinch zoom (VideoZoom), PracticeSection model (+ export/import, list headers, loop).
  Only compile-checked in CI; audio timing needs a test on the iPhone.

- "Integrate the rest" (user picked everything): memory test while recording (RecordView eye button,
  Take.memoryTest, MemoryResultSheet → CountNote.masteryRaw), progress marks + bars (CountListView,
  ProjectRow; Project.eightCountTotal), count-in before every loop (PlayerController.countInOnLoop),
  open .json via CFBundleDocumentTypes (Alternate) + onOpenURL, landscape practice layout,
  BeatDetector (spectral flux + autocorrelation + comb refine; CI video now has a 120 BPM beat),
  PracticeLog (streak, review notifications), Formation (CountNote.formationData, editor, mini maps),
  AirPlay (AVRoutePickerView, isOnTV). UI test testPracticeTools covers most of it.

## Next step
- User tests on device: camera recording, real analysis, Apple Intelligence tips; report any issues.
- Free Apple ID: re-run `./setup-mac.sh --install --no-open` every 7 days.
- Nice-to-haves: README → Next steps.

## Open problems
- Not verifiable in CI: front-camera recording, analysis with a real dancer, Apple Intelligence tips,
  device signing. Needs a test on the iPhone.
