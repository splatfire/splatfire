import XCTest

/// Clicks through the main features on a simulator, taking screenshots.
/// Runs on GitHub's Macs (see .github/workflows/eightcount-ios-build.yml),
/// which pass in a generated test video via SEED_VIDEO.
final class EightCountUITests: XCTestCase {
    private var shotsDir: String {
        ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? NSTemporaryDirectory()
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Saves a screenshot as <SHOTS_DIR>/<name>.png and attaches it to the result.
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(
            to: URL(fileURLWithPath: shotsDir).appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ element: XCUIElement, _ seconds: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: seconds),
                      "Not found: \(element)", file: file, line: line)
    }

    func testMainFlow() throws {
        let video = try XCTUnwrap(ProcessInfo.processInfo.environment["SEED_VIDEO"],
                                  "SEED_VIDEO is not set")
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo"]
        app.launchEnvironment["SEED_VIDEO"] = video
        app.launch()

        // 1. Project list
        let demo = app.staticTexts["Demo"].firstMatch
        waitFor(demo)
        shot("01-project-list")

        // 1b. New Project sheet (then cancel)
        app.buttons["New project"].firstMatch.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        waitFor(cancel, 5)
        sleep(1)
        shot("01b-new-project")
        cancel.tap()
        waitFor(demo, 5)

        // 2. Practice screen with the video
        demo.tap()
        let play = app.buttons["Play"].firstMatch
        waitFor(play)
        waitFor(app.buttons["Loop 8-count 2"], 20)   // 8-count list appears once the video is loaded
        shot("02-practice")

        // 3. Play for a moment, then pause
        play.tap()
        sleep(3)
        shot("03-playing")
        app.buttons["Pause"].firstMatch.tap()

        // 4. Slow down + mirror
        app.buttons["Speed 0.5×"].firstMatch.tap()
        app.buttons["Mirror off"].firstMatch.tap()
        shot("04-half-speed-mirrored")

        // 5. Loop one 8-count
        app.buttons["Loop 8-count 2"].tap()
        sleep(3)
        shot("05-loop-8-count")

        // 6. Notes for 8-count 1
        app.buttons["Edit notes for 8-count 1"].firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        waitFor(done)
        shot("06-notes")
        done.tap()
        // Let the sheet finish closing before using the toolbar menu.
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "Notes sheet didn't close")
        sleep(1)

        // 7. My Takes → Compare
        // Stop the looping 8-count first: the Simulator is slow to open the
        // toolbar menu while the video keeps redrawing.
        let pause = app.buttons["Pause"].firstMatch
        if pause.exists { pause.tap() }
        let takesItem = app.buttons["My Takes (1)"].firstMatch
        let more = app.buttons["More"].firstMatch
        let hittable = NSPredicate(format: "exists == true AND hittable == true")
        for attempt in 0..<4 {
            let moreReady = XCTNSPredicateExpectation(predicate: hittable, object: more)
            if XCTWaiter().wait(for: [moreReady], timeout: 5) == .completed { more.tap() }
            let wait = XCTNSPredicateExpectation(predicate: hittable, object: takesItem)
            if XCTWaiter().wait(for: [wait], timeout: 8) == .completed { break }
            // Menu didn't open properly: close it by tapping the status bar
            // (not the middle of the screen, which hits the video) and retry.
            if attempt < 3 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
                sleep(1)
            }
        }
        if !takesItem.isHittable { shot("07-menu-failed") }
        XCTAssertTrue(takesItem.isHittable, "My Takes menu item not tappable")
        takesItem.tap()
        let takeRow = app.cells.firstMatch
        waitFor(takeRow)
        shot("07-takes")
        takeRow.tap()

        let close = app.buttons["Close"].firstMatch
        waitFor(close, 20)
        // Autoplay: the replay must start by itself (button shows "Pause").
        // Compare opens in ghost mode (tutorial see-through over you, auto-aligned).
        waitFor(app.buttons["Pause"].firstMatch, 15)
        shot("08-compare-autoplay")
        sleep(3)
        shot("09-compare-playing")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("10-compare-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)

        // Switch to side by side (coach mode below is shot in this layout)
        let sideBySide = app.buttons["Side by side"].firstMatch
        if sideBySide.waitForExistence(timeout: 5) {
            sideBySide.tap()
            sleep(2)
            shot("10b-side-by-side")
        }

        // Coach mode from the saved (seeded) analysis: issue shown on the video
        let showIssues = app.buttons["Show issues"].firstMatch
        if showIssues.waitForExistence(timeout: 5) {
            showIssues.tap()
            sleep(4)
            shot("10c-coach-1")
            let next = app.buttons["Next issue"].firstMatch
            if next.waitForExistence(timeout: 3) {
                next.tap()
                sleep(4)
                shot("10d-coach-2")
            }
            let closeCoach = app.buttons["Close coach"].firstMatch
            if closeCoach.exists { closeCoach.tap(); sleep(1) }
        }

        // 7b. Save the take to Photos with the song (the TikTok export)
        let saveVideo = app.buttons["Save video"].firstMatch
        if saveVideo.waitForExistence(timeout: 5) {
            saveVideo.tap()
            let saveToPhotos = app.buttons["Save to Photos"].firstMatch
            waitFor(saveToPhotos, 10)
            sleep(1)
            shot("10e-save-sheet")
            saveToPhotos.tap()
            // If iOS still asks for permission, allow it.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["Allow", "Allow Access", "OK"] {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 3) { button.tap(); break }
            }
            waitFor(app.staticTexts["Saved to Photos"].firstMatch, 180)
            shot("10f-saved")
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() } else { app.swipeDown() }
            sleep(1)
        }

        // 8. AI analysis (the test video has no people in it, so it must end
        //    with a friendly error — the point is that nothing crashes).
        app.buttons["Analyze"].firstMatch.tap()
        // The seeded take already has a report, so the sheet opens on the results.
        let again = app.buttons["Analyze again"].firstMatch
        let first = app.buttons["Analyze my dancing"].firstMatch
        let appeared = NSPredicate { _, _ in again.exists || first.exists }
        expectation(for: appeared, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        sleep(1)
        shot("11-analysis-results")
        (again.exists ? again : first).tap()
        // The test video has no person in it, so a real run must end with the
        // friendly error — the point is that nothing crashes.
        // Check only every 10 s: while Vision is busy, the Simulator can time
        // out reading the screen, and each check is one more chance of that.
        let failedText = app.staticTexts["That didn't work"].firstMatch
        let deadline = Date().addingTimeInterval(240)
        repeat {
            sleep(10)
        } while !failedText.exists && Date() < deadline
        XCTAssertTrue(failedText.exists, "Analysis didn't end with the friendly error")
        shot("12-analysis-done")
    }

    // MARK: - Practice tools

    /// The ✦ practice tools: next-move hint, memory test, cues (just "does
    /// it run without crashing" – a test can't listen), sections, the
    /// build-up coach moving on by itself, the speed ladder and pinch zoom.
    func testPracticeTools() throws {
        let video = try XCTUnwrap(ProcessInfo.processInfo.environment["SEED_VIDEO"],
                                  "SEED_VIDEO is not set")
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo"]
        app.launchEnvironment["SEED_VIDEO"] = video
        app.launch()

        let demo = app.staticTexts["Demo"].firstMatch
        waitFor(demo)
        demo.tap()
        waitFor(app.buttons["Loop 8-count 2"], 20)

        // 0. Automatic beat detection: the test video has a drum hit every
        //    0.5 s (120 BPM) from 0.5 s on.
        let tempoChip = element(app, labelBeginsWith: "Tempo 120")
        waitFor(tempoChip, 10)
        tempoChip.tap()
        let findBeat = app.buttons["Find the beat"].firstMatch
        waitFor(findBeat, 10)
        findBeat.tap()
        let beatResult = app.staticTexts["beatResult"].firstMatch
        waitFor(beatResult, 60)
        shot("19-beat-detected")
        XCTAssertTrue(beatResult.label.contains("120 BPM"), "Beat detection said: \(beatResult.label)")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(findBeat.waitForNonExistence(timeout: 10), "Tempo sheet didn't close")

        // 1. Next-move hint: in the intro, the next 8-count is 1, which has a seeded note.
        waitFor(element(app, labelBeginsWith: "Next, 8-count 1"), 10)
        shot("20-next-move-hint")

        // 2. Practice sheet: memory test on, cues on, a new section.
        let tools = app.buttons["Practice tools"].firstMatch
        waitFor(tools)
        tools.tap()
        waitFor(app.navigationBars["Practice"].firstMatch, 10)
        setSwitch(app, "Hide the video", on: true)
        setSwitch(app, "Count-in", on: true)
        setSwitch(app, "Beat click", on: true)
        setSwitch(app, "Say the counts", on: true)
        setSwitch(app, "Fade as I repeat", on: true)
        sleep(4)   // time for the spoken numbers to be made
        shot("21-practice-sheet-cues")

        let newSection = app.buttons["New Section"].firstMatch
        scrollTo(newSection, in: app)
        newSection.tap()
        let chorus = app.buttons["Chorus"].firstMatch
        waitFor(chorus, 10)
        chorus.tap()
        shot("22-section-editor")
        app.buttons["Save"].firstMatch.tap()
        waitFor(app.buttons["Loop Chorus"].firstMatch, 10)
        shot("23-section-saved")
        app.buttons["Done"].firstMatch.tap()

        // 3. Memory test: the video is covered.
        waitFor(app.staticTexts["MEMORY TEST"].firstMatch, 10)
        shot("24-memory-test")

        // 4. Build up from 8-count 1 (memory test off first).
        tools.tap()
        waitFor(app.navigationBars["Practice"].firstMatch, 10)
        setSwitch(app, "Hide the video", on: false)
        // Reopen the sheet so it starts at the top again (swiping down
        // could close it instead of scrolling).
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
        tools.tap()
        waitFor(app.navigationBars["Practice"].firstMatch, 10)
        let buildUp = element(app, labelBeginsWith: "Build up")
        waitFor(buildUp, 5)
        buildUp.tap()
        // Step 1: one 8-count, then (after 2 runs of the loop) it must move on by itself.
        waitFor(element(app, labelContains: "8-count 1 · run"), 15)
        shot("25-build-up-step-1")
        waitFor(element(app, labelContains: "8-counts 1–2 · run"), 45)
        shot("26-build-up-step-2")
        app.buttons["Next step"].firstMatch.tap()
        waitFor(element(app, labelContains: "8-counts 1–3 · run"), 10)
        app.buttons["Stop the coach"].firstMatch.tap()
        sleep(1)

        // 5. Speed ladder: starts at half speed.
        tools.tap()
        waitFor(app.navigationBars["Practice"].firstMatch, 10)
        let ladder = element(app, labelBeginsWith: "Speed ladder")
        waitFor(ladder, 5)
        ladder.tap()
        waitFor(element(app, labelContains: "at ½×"), 15)
        shot("27-speed-ladder")
        app.buttons["Stop the coach"].firstMatch.tap()

        // 6. The section's Loop button in the list toggles. (The ladder above
        //    looped 8-counts 1–4, which IS the Chorus, so it may already say
        //    "Looping" – then tapping it must stop the loop instead.)
        let loopChorus = app.buttons["Loop Chorus"].firstMatch
        let stopChorus = app.buttons["Stop looping Chorus"].firstMatch
        var toggled = false
        for _ in 0..<6 where !toggled {
            if stopChorus.exists {
                stopChorus.tap()
                toggled = poll(loopChorus, seconds: 6)
            } else if loopChorus.exists {
                loopChorus.tap()
                toggled = poll(stopChorus, seconds: 6)
            } else {
                sleep(2)
            }
        }
        XCTAssertTrue(toggled, "The section's Loop button didn't toggle")
        sleep(2)
        shot("28-section-looping")
        let pause = app.buttons["Pause"].firstMatch
        if pause.exists { pause.tap() }

        // 7. Pinch to zoom, then back to the whole video.
        let videoView = app.otherElements["practiceVideo"].firstMatch
        waitFor(videoView, 5)
        videoView.pinch(withScale: 2.5, velocity: 2)
        let unzoom = app.buttons["Zoomed in. Show the whole video"].firstMatch
        waitFor(unzoom, 10)
        shot("29-zoomed")
        unzoom.tap()
        XCTAssertTrue(unzoom.waitForNonExistence(timeout: 5), "Zoom didn't reset")

        // 8. Progress: long-press 8-count 1 (on screen under the controls) → "Got it".
        // Buttons only: searching every element is slow and can time out in the Simulator.
        let row1 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "8-count 1, starts")).firstMatch
        scrollList(to: row1, in: app)
        row1.press(forDuration: 1.2)
        let gotIt = app.buttons["Got it"].firstMatch
        waitFor(gotIt, 5)
        gotIt.tap()
        waitFor(element(app, labelContains: "Got it: 1 of"), 10)
        shot("30-progress")

        // 9. Formation for 8-count 1: two dancers. Screenshots at each step,
        //    and slow polling (each UI query is heavy on the CI Simulator).
        sleep(2)
        row1.press(forDuration: 1.2)
        sleep(2)
        shot("30b-menu")
        let formationItem = app.buttons["Formation…"].firstMatch
        XCTAssertTrue(poll(formationItem, seconds: 20), "No Formation… menu item")
        let addDancer = app.buttons["Add dancer"].firstMatch
        // A plain .tap() on a context-menu item sometimes doesn't land in the
        // CI Simulator; tap the item's on-screen spot, and retry.
        for _ in 0..<3 where !addDancer.exists {
            let items = app.buttons.matching(identifier: "Formation…").allElementsBoundByIndex
            if let item = items.first(where: { $0.isHittable }) ?? items.first {
                item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            _ = poll(addDancer, seconds: 8)
        }
        shot("30c-formation-opened")
        XCTAssertTrue(addDancer.exists, "Formation editor didn't open")
        addDancer.tap()
        sleep(1)
        addDancer.tap()
        sleep(1)
        shot("31-formation-editor")
        app.buttons["Done"].firstMatch.tap()
        sleep(3)
        shot("32-formation-on-video")
        // The mini map on the video (the list's copy is inside the row's button).
        let onVideo = app.otherElements["videoFormation"].firstMatch
        let asImage = app.images["videoFormation"].firstMatch
        var found = false
        for _ in 0..<4 where !found {
            found = onVideo.exists || asImage.exists
            if !found { sleep(3) }
        }
        XCTAssertTrue(found, "Formation mini map not shown on the video")
    }

    /// Checks every 2 s (instead of continuously) whether `element` exists.
    private func poll(_ element: XCUIElement, seconds: Int) -> Bool {
        for _ in 0..<max(seconds / 2, 1) {
            if element.exists { return true }
            sleep(2)
        }
        return element.exists
    }

    /// Scrolls the 8-count list until `element` is on screen.
    private func scrollList(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 where !(element.exists && element.isHittable) {
            // Drag in the lower part of the screen (the list), not on the video.
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "Can't scroll to \(element)")
    }

    // MARK: - Helpers for the practice test

    private func element(_ app: XCUIApplication, labelBeginsWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func element(_ app: XCUIApplication, labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Scrolls the sheet's list down until `element` can be tapped.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Can't scroll to \(element)")
    }

    /// Turns a Form switch on/off. Taps the switch control itself (SwiftUI
    /// rows can ignore a tap in their middle) and accepts "1"/"0" as well as
    /// "On"/"Off" as the switch's value.
    private func setSwitch(_ app: XCUIApplication, _ labelPrefix: String, on: Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
        scrollTo(toggle, in: app)
        for _ in 0..<3 where isOn(toggle) != on {
            let inner = toggle.switches.firstMatch
            if inner.exists && inner.isHittable {
                inner.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.isOn(toggle) == on },
                                                    object: nil)
            _ = XCTWaiter().wait(for: [changed], timeout: 2)
        }
        if isOn(toggle) != on { shot("fail-switch-\(labelPrefix)") }
        XCTAssertEqual(isOn(toggle), on,
                       "Switch \(labelPrefix) didn't turn \(on ? "on" : "off") (value: \(String(describing: toggle.value)))",
                       file: file, line: line)
    }

    private func isOn(_ toggle: XCUIElement) -> Bool? {
        guard toggle.exists else { return nil }
        switch "\(toggle.value ?? "")".lowercased() {
        case "1", "on", "true": return true
        case "0", "off", "false": return false
        default: return nil
        }
    }
}
