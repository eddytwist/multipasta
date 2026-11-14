import AppKit
import Carbon
import XCTest

// Renders the README screenshots (docs/screenshots/) from the real app with sample data.
//
// Skipped unless MULTIPASTA_README_SHOTS=1 is set for the test runner, so normal test runs never
// touch the pasteboard for it. With xcodebuild, pass it as TEST_RUNNER_MULTIPASTA_README_SHOTS=1.
// The app runs with `enable-testing`: an in-memory history and an isolated defaults suite, so
// nothing from the real clipboard history can appear. The raw PNGs are written to
// MULTIPASTA_README_SHOTS_DIR (or docs/screenshots/raw) and attached to the test result.
@MainActor
final class ReadmeScreenshotTests: XCTestCase {
  private let app = XCUIApplication()
  private let pasteboard = NSPasteboard.general

  private let pinnedText = "Thanks! I'll send the final version by Friday."
  private let urlText = "https://github.com/eddytwist/multipasta"

  private var outputDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["MULTIPASTA_README_SHOTS_DIR"] {
      return URL(fileURLWithPath: path)
    }
    return repositoryRoot.appending(path: "docs/screenshots/raw")
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  }

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["MULTIPASTA_README_SHOTS"] == "1",
      "Set MULTIPASTA_README_SHOTS=1 to render the README screenshots"
    )
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    app.terminate()
    // Leave nothing from the samples on the pasteboard for the real app to pick up.
    pasteboard.clearContents()
    try await super.tearDown()
  }

  func testReadmeScreenshotsLight() throws {
    launch(dark: false)
    fillHistory()
    capturePopup(named: "popup-light")
    openSettings()
    capture(settingsWindow, named: "settings-light")
    showSettingsTab("Quit")
    capture(settingsWindow, named: "quit-settings-light")
  }

  func testReadmeScreenshotsDark() throws {
    launch(dark: true)
    fillHistory()
    capturePopup(named: "popup-dark")
    openSettings()
    capture(settingsWindow, named: "settings-dark")
    showSettingsTab("Quit")
    capture(settingsWindow, named: "quit-settings-dark")
  }

  // MARK: - Steps

  private func launch(dark: Bool) {
    app.launchArguments = [
      "enable-testing",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
      // Read by AppDelegate in testing mode; `-AppleInterfaceStyle` doesn't change the app.
      "-MultipastaTestAppearance", dark ? "dark" : "light",
      // The README names ⇧⌘V; show it in Settings and open the popup with it.
      "-KeyboardShortcuts_popup", shortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey),
      "-KeyboardShortcuts_pin", shortcut(keyCode: kVK_ANSI_P, modifiers: optionKey),
      // `enable-testing` turns Paste on Enter off; show the shipping default.
      "-pasteByDefault", "<true/>",
      // Every sample would show the icon of whatever app happens to be in front.
      "-showApplicationIcons", "<false/>",
      "-popupPosition", "center",
      // The Quit tab as a set-up user sees it; the ⌘Q guard itself stays off.
      "-MultipastaTestAccessibilityGranted", "YES",
      // Sample apps for the Quit tab.
      "-quitGuardApps", #"("com.apple.Terminal", "com.apple.Safari")"#
    ]
    app.launch()
  }

  private func fillHistory() {
    // Pin first, while it's the only item, so the popup sizes itself with the pin section
    // when the other copies arrive.
    copy(pinnedText)
    popUp()
    pin(pinnedText)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.dialogs.firstMatch.waitForNonExistence(timeout: 3), "Popup did not close")

    copy("Meeting moved to 2:30 pm, room B")
    copy("42 Harbour Road, Unit 5, Springfield")
    copy("brew update && brew upgrade")
    copy("#3D7BF7")
    copy(sampleImage())
    copy(urlText)
  }

  /// Pins get a random free key, which the accessibility tree doesn't expose: if the still shows
  /// a symbol rather than a letter, run the test again.
  private func pin(_ title: String) {
    let row = item(title)
    XCTAssertTrue(row.waitForExistence(timeout: 3), "No sample item \(title)")
    hover(row)
    app.typeKey("p", modifierFlags: [.option])
    usleep(1_500_000)
  }

  private func capturePopup(named name: String) {
    popUp()
    let popup = app.dialogs.firstMatch
    // Select the link row by hovering it, like a user would; the pointer isn't captured.
    let row = item(urlText)
    XCTAssertTrue(row.waitForExistence(timeout: 3), "No link sample item")
    hover(row)
    usleep(1_000_000)
    capture(popup, named: name)
  }

  private func openSettings() {
    app.typeKey(",", modifierFlags: [.command])
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings did not open")
    usleep(1_000_000)
  }

  private func showSettingsTab(_ title: String) {
    let toolbarButton = settingsWindow.toolbars.buttons[title].firstMatch
    let button = toolbarButton.exists ? toolbarButton : settingsWindow.buttons[title].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 3), "No \(title) tab")
    button.click()
    usleep(1_200_000)
  }

  // MARK: - Helpers

  private var settingsWindow: XCUIElement {
    // The settings window reports itself as a dialog titled after the selected tab.
    app.dialogs.matching(NSPredicate(format: "title IN %@", ["General", "History", "Quit"])).firstMatch
  }

  private func item(_ title: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: "copy-history-item")
      .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title), "))
      .firstMatch
  }

  private func popUp() {
    app.typeKey("v", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 3), "Popup did not open")
    usleep(600_000)
  }

  private func hover(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).hover()
    usleep(50_000)
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    usleep(200_000)
  }

  private func capture(_ element: XCUIElement, named name: String) {
    let screenshot = element.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)

    do {
      try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
      try screenshot.pngRepresentation.write(to: outputDirectory.appending(path: "\(name).png"))
    } catch {
      // Sandboxed runners can't write there; export the attachments from the .xcresult instead.
      print("README screenshot \(name) not written to \(outputDirectory.path): \(error)")
    }
  }

  private func shortcut(keyCode: Int, modifiers: Int) -> String {
    // KeyboardShortcuts stores a JSON string; quoted, it stays a string in NSArgumentDomain.
    #""{\"carbonKeyCode\":\#(keyCode),\"carbonModifiers\":\#(modifiers)}""#
  }

  private func copy(_ string: String) {
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    usleep(1_500_000)
  }

  private func copy(_ image: NSImage) {
    pasteboard.clearContents()
    pasteboard.setData(image.tiffRepresentation, forType: .tiff)
    usleep(1_500_000)
  }

  /// The app icon from docs/icon.png, or a soft gradient if the runner can't read it.
  private func sampleImage() -> NSImage {
    if let icon = NSImage(contentsOf: repositoryRoot.appending(path: "docs/icon.png")) {
      return icon
    }
    return NSImage(size: NSSize(width: 256, height: 160), flipped: false) { rect in
      NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.48, blue: 0.97, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.36, blue: 0.95, alpha: 1)
      ])?.draw(in: rect, angle: 30)
      return true
    }
  }
}
