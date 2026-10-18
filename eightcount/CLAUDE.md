# EightCount — notes for Claude Code on the owner's Mac

Shared rules + hand-off with Cursor: ../AGENTS.md and ../HANDOFF.md (read first, update last).

Native iPhone app (SwiftUI, SwiftData, AVFoundation, Vision, FoundationModels), iOS 17+ target,
built with Xcode 27. The owner is a beginner — explain in plain words, do the work yourself.

- The Xcode project is GENERATED: edit `project.yml`, then `xcodegen generate`. Never edit or
  commit `EightCount.xcodeproj` (gitignored).
- One command does everything: `./setup-mac.sh --install` (compile check, sign with the
  owner's Apple ID team, install + launch on the USB-connected iPhone via `xcrun devicectl`).
  Logs: `build.log` (compile check), `device-build.log` (signed device build).
- Things only the owner can do (ask them, step by step): sign in under Xcode → Settings →
  Accounts; tap "Trust" on the iPhone; enable Developer Mode (Settings → Privacy & Security);
  with a free Apple ID trust the developer under Settings → General → VPN & Device Management.
- If the bundle ID `io.github.splatfire.eightcount` can't be registered:
  `./setup-mac.sh --install --bundle-id com.<name>.eightcount`.
- Swift 5 language mode (`SWIFT_VERSION: 5.0`). Liquid Glass code is guarded by
  `#if compiler(>=6.2)` + `#available(iOS 26.0, *)` in `EightCount/Design/Glass.swift`.
- UI test: `EightCountUITests` (needs `-seedDemo` + SEED_VIDEO, see
  `.github/workflows/eightcount-ios-build.yml`). CI builds with Xcode 27 + 26 on every push.
- Branch: `claude/nice-bardeen-84bg5p`. Progress log: `../PROGRESS.md`. Docs: `README.md`.
