import AppKit
import Carbon
import XCTest

// Multipasta: list copy end to end, with TextEdit as the front app.
//
// Needs the Multipasta build under test to have Accessibility (it presses ⌘C in TextEdit):
// sign it with the same certificate as the installed app, or add it in System Settings.
// Run with a Latin keyboard layout (ABC), like the other hotkey UI tests.
// TextEdit is closed without saving at the end and launched without restoring windows, so
// nothing is left behind in it.
@MainActor
final class ListCopyUITests: XCTestCase {
  let app = XCUIApplication()
  let textEdit = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
  let pasteboard = NSPasteboard.general
  let listType = NSPasteboard.PasteboardType("com.eddytwist.Multipasta.list")

  private var listRows: XCUIElementQuery {
    app.descendants(matching: .any)
      .matching(identifier: "copy-history-item")
      .matching(NSPredicate(format: "label BEGINSWITH %@", "List, "))
  }

  override func setUp() async throws {
    try await super.setUp()
    // These tests need the build that XCTest launches to be trusted for Accessibility (it posts ⌘C to TextEdit).
    // On a Mac where only the installed app is trusted, the synthetic ⌘C is dropped, so they run only on request.
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["MULTIPASTA_LIST_UI"] == "1",
      "Set TEST_RUNNER_MULTIPASTA_LIST_UI=1 on a Mac where the test build has Accessibility"
    )
    continueAfterFailure = false

    app.launchArguments.append("enable-testing")
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    setKeyboardShortcut("popup", keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)
    setKeyboardShortcut("addToList", keyCode: kVK_ANSI_C, modifiers: cmdKey | shiftKey)
    app.launch()

    pasteboard.clearContents()

    textEdit.launchArguments += [
      "-AppleLanguages", "(en)",
      "-ApplePersistenceIgnoreState", "YES",
      "-NSShowAppCentricOpenPanelInsteadOfUntitledFile", "NO"
    ]
    textEdit.launch()
    openNewTextEditDocument()
  }

  override func tearDown() async throws {
    closeTextEditWithoutSaving()
    app.terminate()
    try await super.tearDown()
  }

  func testAddTwoLinesToListAndPasteThem() throws {
    addToList("line1")
    addToList("line2")

    // One history item for the whole list, with both lines.
    textEdit.typeKey("v", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 3), "Multipasta did not pop up")
    let row = listRows.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 3), "No list in the history")
    XCTAssertEqual(listRows.count, 1)
    XCTAssertTrue(row.label.hasPrefix("List, 2 items, line1⏎line2"), "Unexpected row: \(row.label)")
    app.typeKey(.escape, modifierFlags: [])

    // The whole list is on the clipboard. Reading it here counts as pasting it.
    XCTAssertEqual(pasteboard.string(forType: .string), "line1\nline2")
  }

  func testPastingWithCommandVEndsTheList() throws {
    addToList("line1")
    addToList("line2")

    // Paste the list into TextEdit with ⌘V: TextEdit asks the clipboard for the text.
    let textView = textEdit.textViews.firstMatch
    textView.typeKey(.downArrow, modifierFlags: [.command])
    textView.typeKey(.return, modifierFlags: [])
    textView.typeKey("v", modifierFlags: [.command])
    XCTAssertTrue((textView.value as? String)?.hasSuffix("line1\nline2") == true, "The list wasn't pasted")

    // The next press starts a new list.
    addToList("line3")
    assertHUD("New list · 1")
    XCTAssertEqual(pasteboard.string(forType: .string), "line3")
  }

  func testImageSelectionKeepsTheList() throws {
    // A rich text document with a line of text and an image under it.
    let image = try XCTUnwrap(NSImage(named: NSImage.addTemplateName))
    let attachment = NSTextAttachment()
    attachment.image = image
    let rtfd = try XCTUnwrap(NSAttributedString(attachment: attachment).rtfd(
      from: NSRange(location: 0, length: 1),
      documentAttributes: [:]
    ))
    pasteboard.clearContents()
    pasteboard.setData(rtfd, forType: .rtfd)

    let textView = textEdit.textViews.firstMatch
    textView.click()
    textView.typeKey("a", modifierFlags: [.command])
    textView.typeKey("v", modifierFlags: [.command])
    textView.typeKey(.upArrow, modifierFlags: [.command])
    textView.typeText("line1\n")

    // The text line starts a list.
    textView.typeKey(.upArrow, modifierFlags: [.command])
    textView.typeKey(.rightArrow, modifierFlags: [.command, .shift])
    textEdit.typeKey("c", modifierFlags: [.command, .shift])
    assertHUD("New list · 1")
    XCTAssertTrue(pasteboard.types?.contains(listType) == true)

    // The image alone: refused, and the list is back on the clipboard.
    textView.typeKey(.downArrow, modifierFlags: [.command])
    textView.typeKey(.leftArrow, modifierFlags: [.shift])
    textEdit.typeKey("c", modifierFlags: [.command, .shift])
    assertHUD("Only text can go into a list")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertTrue(pasteboard.types?.contains(listType) == true, "The list wasn't put back")
    XCTAssertFalse(pasteboard.types?.contains(.rtfd) == true)
    XCTAssertEqual(pasteboard.string(forType: .string), "line1")
  }

  // MARK: - Helpers

  private func assertHUD(_ text: String) {
    let hud = app.descendants(matching: .any).matching(identifier: "list-copy-hud").firstMatch
    XCTAssertTrue(hud.waitForExistence(timeout: 3), "No HUD")
    XCTAssertEqual(hud.label, text)
  }

  private func addToList(_ line: String) {
    let textView = textEdit.textViews.firstMatch
    XCTAssertTrue(textView.waitForExistence(timeout: 5), "No TextEdit document")
    textView.click()
    textView.typeKey("a", modifierFlags: [.command])
    textView.typeText(line)
    textView.typeKey("a", modifierFlags: [.command])

    let before = pasteboard.changeCount
    textEdit.typeKey("c", modifierFlags: [.command, .shift])
    // Multipasta presses ⌘C, waits for the copy and writes the list.
    let deadline = Date().addingTimeInterval(3)
    while pasteboard.changeCount == before, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertNotEqual(
      pasteboard.changeCount,
      before,
      "The clipboard didn't change: does this Multipasta build have Accessibility?"
    )
    // Let the copy and the list write settle before the next step.
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    XCTAssertTrue(pasteboard.types?.contains(listType) == true)
  }

  private func openNewTextEditDocument() {
    // With iCloud Drive, TextEdit may open with an Open panel instead of a document.
    let newDocument = textEdit.buttons["New Document"]
    if newDocument.waitForExistence(timeout: 2) {
      newDocument.click()
    } else if !textEdit.textViews.firstMatch.waitForExistence(timeout: 2) {
      textEdit.typeKey("n", modifierFlags: [.command])
    }
    XCTAssertTrue(textEdit.textViews.firstMatch.waitForExistence(timeout: 5), "No TextEdit document")
  }

  private func closeTextEditWithoutSaving() {
    guard textEdit.state == .runningForeground || textEdit.state == .runningBackground else {
      return
    }
    textEdit.activate()
    for window in textEdit.windows.allElementsBoundByIndex where window.exists {
      // Empty the document first, so that there is nothing worth keeping.
      let textView = window.textViews.firstMatch
      if textView.exists {
        textView.typeKey("a", modifierFlags: [.command])
        textView.typeKey(.delete, modifierFlags: [])
      }
      window.typeKey("w", modifierFlags: [.command])
      for title in ["Delete", "Don’t Save", "Don't Save"] {
        let button = textEdit.buttons[title]
        if button.waitForExistence(timeout: 1) {
          button.click()
          break
        }
      }
    }
    textEdit.terminate()
  }

  // KeyboardShortcuts reads JSON strings from UserDefaults.standard; launch arguments put
  // them in the argument domain, so the user's own shortcuts stay untouched.
  private func setKeyboardShortcut(_ name: String, keyCode: Int, modifiers: Int) {
    app.launchArguments.append(contentsOf: [
      "-KeyboardShortcuts_\(name)",
      #""{\"carbonKeyCode\":\#(keyCode),\"carbonModifiers\":\#(modifiers)}""#
    ])
  }
}
