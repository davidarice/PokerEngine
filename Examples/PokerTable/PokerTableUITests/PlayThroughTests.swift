import XCTest

/// Taps through the app as the dealer does: seats, every player's action, an all-in, the run count and the showdown.
final class PlayThroughTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testDealerEntersEveryAction() {
        keepScreenshot("The table before the first hand")
        tap(button("Add bot"))
        tap(button("Add bot"))
        keepScreenshot("Five seats")
        app.buttons["Remove Bot 3"].tap()
        tap(button("Add bot"))

        // A quiet hand, called and checked down to the showdown.
        tap(button("Deal"))
        keepScreenshot("The first decision")

        // A stack corrected mid-hand, then put back so the all-in below still leaves nobody to bet. Player 0 sits in
        // the second seat.
        tap(app.buttons["Settings"])
        let startingStack = { (label: String) in
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        tap(app.steppers.firstMatch.buttons["Increment"])
        XCTAssertTrue(startingStack("Bot 2 started with 210").waitForExistence(timeout: 10), "No correction")
        keepScreenshot("A stack corrected")
        tap(app.steppers.firstMatch.buttons["Decrement"])
        XCTAssertTrue(startingStack("Bot 2 started with 200").waitForExistence(timeout: 10), "No correction back")
        tap(app.buttons["Done"])

        var isFirstShow = true
        enterUntilTheHandEnds(among: ["Show", "Check", "Call"]) { label in
            if label == "Show", isFirstShow {
                isFirstShow = false
                self.keepScreenshot("The showdown")
            }
        }
        keepScreenshot("The end of the first hand")
        XCTAssertFalse(isFirstShow, "The hand never reached a showdown")

        // A misdeal, voided, then everyone folds to the blinds, who chop. Neither moves a chip.
        tap(app.buttons["Settings"])
        tap(button("Reset every stack"))
        tap(app.buttons["Done"])
        tap(button("Next hand"))
        tap(app.buttons["Settings"])
        tap(button("Void this hand"))
        XCTAssertTrue(app.staticTexts["Hand voided: every chip went back."].waitForExistence(timeout: 10), "No void")
        tap(button("Next hand"))
        let chop = button("Chop")
        for _ in 0..<10 where !chop.waitForExistence(timeout: 2) {
            tap(button("Fold"))
        }
        keepScreenshot("Folded to the blinds")
        tap(chop)
        XCTAssertTrue(app.staticTexts["The blinds chopped."].waitForExistence(timeout: 10), "No chop")

        // An all-in called by everyone, run twice. A split pot in the first hand can leave two stacks above the rest,
        // and then two players have chips left to bet after the all-in, so every stack went back to the buy-in above.
        tap(button("Next hand"))
        tap(button("All in"))
        keepScreenshot("All in chosen")
        tap(button("Raise to"))
        var isFirstRunCount = true
        enterUntilTheHandEnds(among: ["2×", "Show", "Call"]) { label in
            if label == "2×", isFirstRunCount {
                isFirstRunCount = false
                self.keepScreenshot("The run count")
            }
        }
        keepScreenshot("Two boards")
        XCTAssertFalse(isFirstRunCount, "The table was never asked for a run count")

        tap(app.buttons["Hand log"])
        let rankedHand = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " · shown · ")).firstMatch
        XCTAssertTrue(rankedHand.waitForExistence(timeout: 10), "The log ranks no hand")
        keepScreenshot("The hand log")
        tap(app.buttons["Done"])
        tap(app.buttons["Settings"])
        keepScreenshot("Settings")
        tap(app.buttons["Done"])

        while button("Add bot").isEnabled {
            tap(button("Add bot"))
        }
        keepScreenshot("A full table")
        tap(button("Next hand"))
        keepScreenshot("Ten seats in a hand")

        // Pot-Limit Omaha from the next hand: four cards a seat, and no raise above the pot. Ten stack steppers push
        // the void below the fold, and the form only builds rows on screen.
        tap(app.buttons["Settings"])
        let void = app.buttons["Void this hand"]
        for _ in 0..<6 where !void.exists {
            app.swipeUp()
        }
        tap(void)
        tap(app.buttons["Settings"])
        tap(app.buttons["Pot-Limit Omaha"])
        tap(app.buttons["Done"])
        tap(button("Next hand"))
        tap(button("Max"))
        XCTAssertTrue(button("Raise to 7").waitForExistence(timeout: 10), "No pot-limit raise")
        keepScreenshot("Ten seats of Omaha")
    }

    private func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) never appeared")
        element.tap()
    }

    /// Taps the first of `labels` on screen, over and over, until "Next hand" appears.
    private func enterUntilTheHandEnds(among labels: [String], before: (String) -> Void) {
        let nextHand = button("Next hand")
        for _ in 0..<120 {
            if nextHand.exists {
                return
            }
            guard let label = labels.first(where: { button($0).exists && button($0).isEnabled }) else {
                continue
            }
            before(label)
            button(label).tap()
        }
        XCTFail("The hand never ended")
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
