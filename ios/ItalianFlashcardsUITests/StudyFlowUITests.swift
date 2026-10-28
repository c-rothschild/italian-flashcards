import XCTest

/// Drives the real app: flip a card, pick categories, and go through a Learn session
/// (wrong answer + override, empty answer = don't know, retype, rounds, finish).
/// Set SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR for xcodebuild) to save screenshots.
final class StudyFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshProgress"] // start from no progress, don't sync it
        app.launch()
    }

    private func snap(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }

    private func tab(_ name: String) {
        app.buttons[name].firstMatch.tap()
    }

    func testStudyFlow() throws {
        // Flashcards: tap the card to flip it.
        XCTAssertTrue(app.navigationBars["Flashcards"].waitForExistence(timeout: 10))
        snap("1_flashcards")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        snap("2_flipped")

        // Categories: wait for the cloud check, then study just Animals.
        tab("Categories")
        let upToDate = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Up to date'")).firstMatch
        XCTAssertTrue(upToDate.waitForExistence(timeout: 20), "downloaded the cards from GitHub")
        snap("3_categories")
        app.buttons["None"].tap()
        let animals = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Animals'")).firstMatch
        XCTAssertTrue(animals.waitForExistence(timeout: 5))
        animals.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(animals.value as? String, "1")

        // Learn: skip the first word (it moves to the end), then a wrong answer offers the override.
        tab("Learn")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        snap("4_learn")
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Skipped'")).firstMatch.waitForExistence(timeout: 3))
        snap("4b_skipped")
        // Undo brings it straight back; skip it again.
        app.buttons["Undo last skip"].tap()
        XCTAssertFalse(app.buttons["Undo last skip"].exists)
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.buttons["Undo last skip"].waitForExistence(timeout: 3))
        field.tap()
        field.typeText("zzzz\n")
        let override = app.buttons["Override: I was right"]
        XCTAssertTrue(override.waitForExistence(timeout: 5))
        snap("5_wrong")
        override.tap()

        // The skipped word comes back in the next round.
        let continueRound = app.buttons["Continue to next round"]
        XCTAssertTrue(continueRound.waitForExistence(timeout: 5))
        continueRound.tap()

        // An empty answer counts as "Don't know" (no override), then retype.
        XCTAssertTrue(app.buttons["Answer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Skip"].exists, "no skipping the last word left")
        field.typeText("\n")
        let answer = app.staticTexts["expectedAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Override: I was right"].exists)
        snap("6_dont_know")
        let missed = answer.label
        field.typeText("not it\n")
        XCTAssertTrue(app.staticTexts["That doesn't match yet. Copy the answer above."].waitForExistence(timeout: 3))
        field.clearAndType(missed + "\n")

        // Round summary, then the missed card comes back; answer it to finish.
        let next = app.buttons["Continue to next round"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        snap("7_summary")
        next.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(missed + "\n")
        XCTAssertTrue(app.staticTexts["You've learned all 2 terms! 🎉"].waitForExistence(timeout: 8))
        snap("8_done")

        // Put the selection back for normal use.
        tab("Categories")
        app.buttons["All"].tap()
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        guard let current = value as? String, !current.isEmpty else { typeText(text); return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
