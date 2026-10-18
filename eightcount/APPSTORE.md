# Putting EightCount on the App Store

Plan: **free app first** (one-time "Pro" unlock in a later update).
Steps marked **(you)** need your Apple ID, legal name, payment or a click on
Apple's websites. Everything else is already done in this repository.

## Already done in the code

- Privacy manifest `EightCount/Resources/PrivacyInfo.xcprivacy` (no tracking,
  no data collected; the two system APIs the app uses are declared). CI checks
  it's inside the app.
- Privacy policy: [`PRIVACY.md`](PRIVACY.md), and in the app under ⚙ →
  **About & Privacy**.
- `ITSAppUsesNonExemptEncryption = NO` (no export-compliance question per build).
- App icons (iPhone + Apple Watch), 1024 × 1024, no transparency.
- Camera / Photos permission texts.
- Built with Xcode 26/27 (Apple requires the iOS 26 SDK or newer for uploads
  since 28 April 2026).
- Devices: every iPhone that runs iOS 17 or newer (incl. the foldable
  **iPhone Duo**: layouts follow the available space, as Apple asks), **all
  iPads** with iPadOS 17+ (any orientation, Split View / Stage Manager), and
  **Macs with Apple silicon** (as "Designed for iPad").
- App Store screenshots: every CI run takes them on a 6.9-inch iPhone and a
  13-inch iPad simulator → GitHub → Actions → newest "EightCount iOS build" →
  artifacts **ui-screenshots-iPhone** / **ui-screenshots-iPad**.
- TestFlight upload workflow (`.github/workflows/eightcount-testflight.yml`),
  waiting for 4 secrets (step 4).

## 1. Join the Apple Developer Program (you) – 99 USD / year

1. On your iPhone or Mac, open <https://developer.apple.com/programs/enroll/>
   (or the **Apple Developer** app → Account → Enroll).
2. Sign in with the Apple ID you use in Xcode. It needs two-factor
   authentication.
3. Choose **Individual / Sole Proprietor**. Use your real legal name (it is
   shown on the App Store as the seller). Apple requires you to be of legal
   age where you live.
4. Pay. Approval for individuals is often quick (hours to a couple of days).
   Wait for the "Welcome to the Apple Developer Program" email.

## 2. Switch the Mac to the paid team (you, 2 minutes)

1. Xcode → Settings → Accounts → your Apple ID → you should now see a team
   with your name that is **not** "(Personal Team)". Note its Team ID
   (developer.apple.com → Account → Membership details).
2. In Terminal:
   ```sh
   cd ~/splatfire/eightcount && ./setup-mac.sh --install --team YOURTEAMID
   ```
   From now on installs on your iPhone last a **year**, not 7 days.

> Not sure (can't test it from here): if Xcode says the bundle ID
> `io.github.splatfire.eightcount` is "not available", it may still belong to
> the old Personal Team. Tell me – we then pick a new bundle ID (the app will
> install as a second, empty copy; export your projects first).

## 3. Create the app in App Store Connect (you)

<https://appstoreconnect.apple.com> → **Apps** → **+** → **New App**:

| Field | Value |
|---|---|
| Platform | iOS |
| Name | EightCount (if taken: "EightCount: Learn Dances") |
| Primary language | English (U.S.) |
| Bundle ID | io.github.splatfire.eightcount |
| SKU | eightcount-1 |
| User access | Full access |

## 4. Let GitHub upload builds (you, once) – then I take over

1. App Store Connect → **Users and Access** → **Integrations** → **App Store
   Connect API** → **+** → name "GitHub", access **App Manager** → Generate.
2. Download the `.p8` key file (only possible once!). Note the **Key ID** and
   the **Issuer ID** shown above the list.
3. In Terminal: `base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy`
4. GitHub → splatfire/splatfire → **Settings → Secrets and variables →
   Actions → New repository secret**, four times:
   `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (paste), `APPLE_TEAM_ID`.

After that, every push builds and uploads automatically. Builds appear under
**TestFlight** after Apple's processing (usually 5–30 min).

## 5. Fill in the store page (you, copy & paste)

**Subtitle** (30 characters max): `Learn any dance, 8 at a time`

**Promotional text:**
Learn any choreography from a tutorial video: split it into 8-counts, loop the hard parts, slow it down, and film yourself to compare.

**Description:**
EightCount turns any dance tutorial or practice video into 8-counts you can learn one at a time.

• Split the video into 8-counts: type the BPM, tap along, or let the app find the beat
• Loop one 8-count or a whole section, slow down to ½× or ¼× without changing the pitch, mirror the video
• Notes, lyrics and pose snapshots for every 8-count
• Practice coach: build it up 8-count by 8-count, or run a speed ladder from ½× to full speed
• Spoken count-in "5, 6, 7, 8", beat click, your own move names
• Memory test: hide the tutorial and dance from memory, then mark what you forgot
• Record yourself with the front camera and compare side by side or as a see-through ghost
• On-device AI analysis: arms, legs, posture and timing, with tips
• Formations, progress per 8-count, practice streaks
• Apple Watch remote and AirPlay to your TV

No account, no ads, no tracking. Your videos never leave your iPhone.

**Keywords** (100 characters max):
`dance,choreography,kpop,dance practice,8 count,mirror,slow motion,loop,tutorial,learn dance`

**Support URL:** <https://github.com/splatfire/splatfire/issues>
**Privacy Policy URL:**
<https://github.com/splatfire/splatfire/blob/claude/nice-bardeen-84bg5p/eightcount/PRIVACY.md>
(change it to the main branch once the pull request is merged)

**Category:** Health & Fitness (secondary: Education)

**App Privacy** (questionnaire): "No, we do not collect data from this app."

**Age rating:** answer **None / No** to every question (no violence, no
user-generated content shared with others, no web browsing, no chat). Expected
result: 4+.

**Price:** Free. All territories.

**Screenshots:** from the CI artifacts: iPhone 6.9-inch AND iPad 13-inch
(needed because the app supports iPad). Upload 3–6 each, e.g. practice
screen, Practice sheet, record (ghost), compare, analysis.

**Mac:** Pricing and Availability → **iPhone and iPad Apps on Apple Silicon
Macs** → leave "Make this app available" ticked. (Optional: "Apple Vision
Pro" can stay off.)

**App Review notes** (helps the reviewer):
> No account needed. Import any dance video from Photos or Files (a sample
> can be any short music video). The camera is used only to record yourself
> dancing; nothing is uploaded. Apple Watch app is a remote for the iPhone app.

## 6. Submit (you)

1. TestFlight: install the build on your iPhone and do a last check.
2. App Store tab → version 1.0 → **Build** → choose it → **Add for Review** →
   **Submit**.
3. Review usually takes about a day or two. If Apple rejects something, paste
   me the message.
