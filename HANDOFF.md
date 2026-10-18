# Where we left off

> **MOVED (18 Oct 2026):** EightCount now lives in its own repo,
> **https://github.com/splatfire/eightcount-app** (branch `main`). Work there –
> this branch is no longer updated. On the Mac: `~/eightcount-app`.


_Last updated: 18 October 2026 · by Claude Code (cloud session)_

## State right now

- EightCount builds and all CI checks are green (Xcode 27 + 26, UI tests on
  iPhone 6.9" and iPad 13" simulators).
- Recent work: App Store prep (privacy manifest, `eightcount/PRIVACY.md`,
  in-app About & Privacy, `eightcount/APPSTORE.md` with store texts),
  universal app (iPhone incl. iPhone Duo, iPad, Apple-silicon Mac),
  fixes for the memory-test recording crash and the countdown beeps.
- Plan: free app on the App Store first; one-time "Pro" unlock later.

## Waiting on the owner

1. Join the Apple Developer Program (99 USD/year), then follow
   `eightcount/APPSTORE.md` from step 2.
2. Test on the iPhone after `./setup-mac.sh --update`:
   - memory test while recording (eye button) – no crash any more?
   - countdown beeps on time with 3-2-1? If not: beep before/after the
     number, by how much, Bluetooth headphones yes/no?
3. Older open questions: does the Apple Watch app install/work? After a 0.75×
   recording, is the 1× replay gap constant or growing?

## Next steps (for whichever app works next)

- When the owner has the paid team: help with `setup-mac.sh --install --team …`,
  App Store Connect, the 4 GitHub secrets for TestFlight.
- If the bundle ID is "not available" on the paid team: pick a new one
  (`--bundle-id`), warn that it installs as a second, empty app.
- Add an iPhone Duo UI-test run to CI once GitHub's Xcode has the iOS 27.1
  SDK (CI currently builds with the iOS 27.0 SDK).
- Later: one-time Pro unlock (StoreKit 2).

## Half-finished / caution

- Nothing half-finished.
- Don't build App Store uploads with a beta Xcode.
