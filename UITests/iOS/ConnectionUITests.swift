import XCTest

/// End-to-end tests of the iOS app against a real server, driven through the accessibility
/// tree (the same tree VoiceOver uses). Configure with TEST_RUNNER_-prefixed variables:
///
///     TEST_RUNNER_ACCESSH_TEST_HOST=example.com TEST_RUNNER_ACCESSH_TEST_USER=me \
///     TEST_RUNNER_ACCESSH_TEST_KEY=/Users/me/.ssh/id_ed25519 xcodebuild test …
@MainActor
final class ConnectionUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipIf(environment["ACCESSH_TEST_HOST"] == nil, "No test server configured")
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "ACCESSH_SEED_HOST": environment["ACCESSH_TEST_HOST"] ?? "",
            "ACCESSH_SEED_USER": environment["ACCESSH_TEST_USER"] ?? "",
            "ACCESSH_SEED_KEY_PATH": environment["ACCESSH_TEST_KEY"] ?? "",
        ]
        app.launch()
        return app
    }

    func testConnectRunCommandAndReadOutputThroughAccessibility() throws {
        let app = launchApp()

        // The host row is one accessibility element named after the host.
        let hostRow = app.buttons["Test Server"].firstMatch
        XCTAssertTrue(hostRow.waitForExistence(timeout: 10), "Host row not found")
        hostRow.tap()

        // First connection: the host-key sheet appears unless the key is already trusted.
        let trust = app.buttons["Trust and Connect"]
        if trust.waitForExistence(timeout: 15) {
            XCTAssertTrue(app.staticTexts["SHA-256 fingerprint"].exists || app.otherElements["SHA-256 fingerprint"].exists)
            trust.tap()
        }

        let commandField = app.textFields["Command"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 20), "Command field never appeared")
        commandField.tap()
        commandField.typeText("echo ACCESS_$((6*7))\n")

        // The output must be reachable as a terminal line element, exactly as VoiceOver sees it.
        let output = app.staticTexts.matching(NSPredicate(format: "label == %@", "ACCESS_42")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 15), "Command output was not exposed to accessibility")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Terminal after command"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        commandField.typeText("false\n")
        sleep(2)
        commandField.typeText("exit\n")
        let reconnect = app.buttons["Reconnect"].firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 15), "Session did not report the shell exiting")
    }

    func testAccessibilityAuditOfHostList() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["Test Server"].firstMatch.waitForExistence(timeout: 10))
        try app.performAccessibilityAudit()
    }

    /// The Default Input Mode setting decides how a new session starts.
    func testDefaultInputModeSetting() throws {
        let app = launchApp()
        func setDefault(_ mode: String) {
            app.buttons["Settings"].firstMatch.tap()
            app.buttons["Keyboard"].firstMatch.tap()
            app.buttons["Default Input Mode"].firstMatch.tap()
            app.buttons[mode].firstMatch.tap()
            XCTAssertEqual(app.buttons["Default Input Mode"].firstMatch.value as? String, mode)
            app.navigationBars["Keyboard"].buttons.element(boundBy: 0).tap()
            app.buttons["Done"].firstMatch.tap()
        }
        setDefault("Direct Keys")
        addTeardownBlock { @MainActor in
            let cleanup = XCUIApplication()
            cleanup.launch()
            cleanup.buttons["Settings"].firstMatch.tap()
            cleanup.buttons["Keyboard"].firstMatch.tap()
            cleanup.buttons["Default Input Mode"].firstMatch.tap()
            cleanup.buttons["Automatic"].firstMatch.tap()
        }

        app.buttons["Test Server"].firstMatch.tap()
        let trust = app.buttons["Trust and Connect"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }
        let keys = app.otherElements["Terminal keys"].firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 20), "Session didn't start in Direct Keys")
        XCTAssertFalse(app.textFields["Command"].exists, "VoiceOver must not reach the hidden Command field in Direct Keys")
    }

    /// The Shell Integration screen reports the server's installation and shows a removal
    /// review. The review is cancelled, so the server is never changed by this test.
    func testShellIntegrationScreen() throws {
        let app = launchApp()
        app.buttons["Test Server"].firstMatch.tap()
        let trust = app.buttons["Trust and Connect"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }
        XCTAssertTrue(app.textFields["Command"].waitForExistence(timeout: 20) || app.otherElements["Terminal keys"].waitForExistence(timeout: 5))

        app.buttons["Terminal Actions"].firstMatch.tap()
        let entry = app.buttons["Shell Integration…"].firstMatch
        for _ in 0..<4 where !entry.exists { app.collectionViews.firstMatch.swipeUp() }
        entry.tap()
        let active = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Shell integration is active for bash'")).firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 15), "Integration wasn't reported as active")
        func row(_ label: String, _ value: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", label, value)).firstMatch
        }
        let installed = row("Installed", "Version 1.0.0")
        for _ in 0..<6 where !installed.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(installed.exists, "The installed script wasn't detected on the server")
        XCTAssertTrue(row("Loaded From", ".bashrc").exists)
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait]) { issue in
            // Same documented exemption as SettingsUITests: system navigation-bar buttons on glass.
            guard issue.auditType == .contrast, let element = issue.element, element.elementType == .button else { return false }
            return app.navigationBars.buttons.allElementsBoundByIndex.contains { $0.label == element.label }
        }

        let remove = app.buttons["Remove…"].firstMatch
        while !remove.isHittable { app.swipeUp() }
        remove.tap()
        XCTAssertTrue(app.navigationBars["Review Removal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Modify .bashrc: remove'")).firstMatch.exists)
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .trait]) { issue in
            // Same documented exemption as SettingsUITests: system navigation-bar buttons on glass.
            guard issue.auditType == .contrast, let element = issue.element, element.elementType == .button else { return false }
            return app.navigationBars.buttons.allElementsBoundByIndex.contains { $0.label == element.label }
        }
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Shell Integration"].waitForExistence(timeout: 5))
    }
}
