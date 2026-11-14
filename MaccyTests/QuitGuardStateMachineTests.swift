import CoreGraphics
import Foundation
import Testing
@testable import Maccy

@Suite("⌘Q guard state machine")
final class QuitGuardStateMachineTests {
  typealias Machine = QuitGuardStateMachine

  static let qKey = CGKeyCode(12)
  static let wKey = CGKeyCode(13)
  static let tabKey = CGKeyCode(48)
  static let graveKey = CGKeyCode(50)
  static let escapeKey = CGKeyCode(53)
  static let terminal = Machine.App(bundleIdentifier: "com.apple.Terminal", processIdentifier: 101, name: "Terminal")
  static let safari = Machine.App(bundleIdentifier: "com.apple.Safari", processIdentifier: 202, name: "Safari")

  var machine = Machine(guardedBundleIdentifiers: [terminal.bundleIdentifier])

  static func keyDown(
    _ keyCode: CGKeyCode = qKey,
    flags: CGEventFlags = .maskCommand,
    isRepeat: Bool = false,
    isMarked: Bool = false,
    app: Machine.App? = terminal
  ) -> Machine.Event {
    .keyDown(
      keyCode: keyCode, isQuitKey: keyCode == qKey, flags: flags, isRepeat: isRepeat, isMarked: isMarked, app: app
    )
  }

  static func keyUp(_ keyCode: CGKeyCode = qKey, isMarked: Bool = false) -> Machine.Event {
    .keyUp(keyCode: keyCode, isMarked: isMarked)
  }

  /// Presses ⌘Q in Terminal and returns the hold id.
  func startHold() throws -> UInt64 {
    let output = machine.handle(Self.keyDown())
    #expect(output.verdict == .swallow)
    guard case let .startHold(app, holdID) = try #require(output.effects.last) else {
      Issue.record("Expected startHold, got \(output.effects)")
      return 0
    }
    #expect(app == Self.terminal)
    return holdID
  }

  @Test("⌘Q in a guarded app is swallowed and starts a hold")
  func keyDownInGuardedAppStartsHold() throws {
    let holdID = try startHold()
    #expect(machine.phase == .holding(app: Self.terminal, keyCode: Self.qKey, holdID: holdID))
  }

  @Test("Key repeats while holding are swallowed")
  func repeatsAreSwallowed() throws {
    let holdID = try startHold()
    for _ in 0..<5 {
      #expect(machine.handle(Self.keyDown(isRepeat: true)) == .swallow)
    }
    #expect(machine.phase == .holding(app: Self.terminal, keyCode: Self.qKey, holdID: holdID))
  }

  @Test("Releasing Q before the deadline cancels the hold")
  func keyUpBeforeDeadlineCancels() throws {
    let holdID = try startHold()
    #expect(machine.handle(Self.keyUp()) == Machine.Output(verdict: .swallow, effects: [.cancelHold(holdID: holdID)]))
    #expect(machine.phase == .idle)
    // The deadline of the cancelled hold does nothing.
    #expect(machine.handle(.deadline(holdID: holdID)) == .pass)
  }

  @Test("Releasing ⌘ first cancels the hold, and Q's repeats don't type \"q\"")
  func commandUpBeforeDeadlineCancels() throws {
    let holdID = try startHold()
    #expect(
      machine.handle(.flagsChanged(flags: [])) == Machine.Output(verdict: .pass, effects: [.cancelHold(holdID: holdID)])
    )
    #expect(machine.phase == .suppressing(keyCode: Self.qKey))
    for _ in 0..<3 {
      #expect(machine.handle(Self.keyDown(flags: [], isRepeat: true)) == .swallow)
    }
    // ⌘ comes back while Q is still down: still swallowed.
    #expect(machine.handle(Self.keyDown(isRepeat: true)) == .swallow)
    #expect(machine.handle(Self.keyUp()) == .swallow)
    #expect(machine.phase == .idle)
    // Typing goes on as usual.
    #expect(machine.handle(Self.keyDown(flags: [])) == .pass)
  }

  @Test("Adding ⇧ while holding cancels the hold, and the repeats don't become ⌘⇧Q (Log Out)")
  func extraModifierCancels() throws {
    let holdID = try startHold()
    let output = machine.handle(.flagsChanged(flags: [.maskCommand, .maskShift]))
    #expect(output == Machine.Output(verdict: .pass, effects: [.cancelHold(holdID: holdID)]))
    #expect(machine.handle(Self.keyDown(flags: [.maskCommand, .maskShift], isRepeat: true)) == .swallow)
    #expect(machine.handle(Self.keyUp()) == .swallow)
    #expect(machine.phase == .idle)
  }

  @Test("Reaching the deadline quits the app and swallows the rest of the press")
  func deadlineQuits() throws {
    let holdID = try startHold()
    let output = machine.handle(.deadline(holdID: holdID))
    #expect(output.effects == [.quit(app: Self.terminal, keyCode: Self.qKey, holdID: holdID)])
    #expect(machine.phase == .suppressing(keyCode: Self.qKey))

    #expect(machine.handle(Self.keyDown(isRepeat: true)) == .swallow)
    #expect(machine.handle(Self.keyUp()) == .swallow)
    #expect(machine.phase == .idle)
  }

  @Test("The re-posted, marked ⌘Q passes")
  func markedEventsPass() throws {
    let holdID = try startHold()
    _ = machine.handle(.deadline(holdID: holdID))
    #expect(machine.handle(Self.keyDown(isMarked: true)) == .pass)
    #expect(machine.handle(Self.keyUp(isMarked: true)) == .pass)
    #expect(machine.phase == .suppressing(keyCode: Self.qKey))
  }

  @Test("⌘Q in an app that is not on the list passes")
  func nonGuardedAppPasses() {
    #expect(machine.handle(Self.keyDown(app: Self.safari)) == .pass)
    #expect(machine.phase == .idle)
  }

  @Test("⌘Q passes while the keys go elsewhere (Multipasta's own popup is key)")
  func keysElsewherePass() {
    // The tap reports no app while a Multipasta window is key, even if Terminal is frontmost.
    #expect(machine.handle(Self.keyDown(app: nil)) == .pass)
    #expect(machine.handle(Self.keyUp()) == .pass)
    #expect(machine.phase == .idle)
  }

  @Test("An empty list lets everything pass")
  func emptyListPasses() {
    machine.guardedBundleIdentifiers = []
    #expect(machine.handle(Self.keyDown()) == .pass)
  }

  @Test("⌘Q with other modifiers passes", arguments: [
    CGEventFlags([.maskCommand, .maskShift]),
    CGEventFlags([.maskCommand, .maskAlternate]),
    CGEventFlags([.maskCommand, .maskControl]),
    CGEventFlags([])
  ])
  func otherModifiersPass(flags: CGEventFlags) {
    #expect(machine.handle(Self.keyDown(flags: flags)) == .pass)
    #expect(machine.phase == .idle)
  }

  @Test("Caps Lock doesn't stop the guard")
  func capsLockIsIgnored() {
    let output = machine.handle(Self.keyDown(flags: [.maskCommand, .maskAlphaShift]))
    #expect(output.verdict == .swallow)
  }

  @Test("Other shortcuts in a guarded app pass")
  func otherShortcutsPass() {
    #expect(machine.handle(Self.keyDown(Self.wKey)) == .pass)
    #expect(machine.handle(Self.keyUp(Self.wKey)) == .pass)
    #expect(machine.handle(.flagsChanged(flags: [])) == .pass)
  }

  @Test("Another key while holding cancels the hold and passes; Q's key up is still swallowed")
  func otherKeyWhileHoldingCancels() throws {
    let holdID = try startHold()
    #expect(
      machine.handle(Self.keyDown(Self.wKey)) == Machine.Output(verdict: .pass, effects: [.cancelHold(holdID: holdID)])
    )
    #expect(machine.phase == .suppressing(keyCode: Self.qKey))
    #expect(machine.handle(Self.keyDown(Self.wKey, isRepeat: true)) == .pass)
    #expect(machine.handle(Self.keyUp(Self.wKey)) == .pass)
    #expect(machine.handle(Self.keyUp()) == .swallow)
    #expect(machine.phase == .idle)
  }

  @Test("⌘Q in the app switcher (⌘Tab, and ⌘` after it) passes", arguments: [false, true])
  func appSwitcherPasses(alsoGrave: Bool) {
    #expect(machine.handle(.flagsChanged(flags: .maskCommand)) == .pass)
    #expect(machine.handle(Self.keyDown(Self.tabKey)) == .pass)
    #expect(machine.handle(Self.keyUp(Self.tabKey)) == .pass)
    if alsoGrave {
      #expect(machine.handle(Self.keyDown(Self.graveKey)) == .pass)
    }
    #expect(machine.isInAppSwitcher)
    // Q quits the app selected in the switcher: the Dock must get it.
    #expect(machine.handle(Self.keyDown()) == .pass)
    #expect(machine.handle(Self.keyUp()) == .pass)
    #expect(machine.phase == .idle)

    // ⌘ released: the switcher is closed and the guard is back.
    #expect(machine.handle(.flagsChanged(flags: [])) == .pass)
    #expect(!machine.isInAppSwitcher)
    #expect(machine.handle(Self.keyDown()).verdict == .swallow)
  }

  @Test("Tab without ⌘ doesn't count as the app switcher")
  func plainTabIsNotSwitcher() {
    _ = machine.handle(Self.keyDown(Self.tabKey, flags: []))
    #expect(!machine.isInAppSwitcher)
    #expect(machine.handle(Self.keyDown()).verdict == .swallow)
  }

  @Test("⌘` without ⌘Tab (cycling windows) doesn't open the switcher: ⌘Q is guarded")
  func graveAloneIsNotSwitcher() {
    _ = machine.handle(.flagsChanged(flags: .maskCommand))
    #expect(machine.handle(Self.keyDown(Self.graveKey)) == .pass)
    #expect(!machine.isInAppSwitcher)
    #expect(machine.handle(Self.keyDown()).verdict == .swallow)
  }

  @Test("Esc closes the switcher: ⌘Tab, Esc, ⌘Q is guarded")
  func escapeClosesSwitcher() {
    _ = machine.handle(.flagsChanged(flags: .maskCommand))
    _ = machine.handle(Self.keyDown(Self.tabKey))
    #expect(machine.handle(Self.keyDown(Self.escapeKey)) == .pass)
    #expect(!machine.isInAppSwitcher)
    #expect(machine.handle(Self.keyDown()).verdict == .swallow)
  }

  @Test("A new frontmost app closes the switcher state")
  func frontmostChangeClosesSwitcher() {
    _ = machine.handle(.flagsChanged(flags: .maskCommand))
    _ = machine.handle(Self.keyDown(Self.tabKey))
    #expect(machine.handle(.frontmostAppChanged) == .pass)
    #expect(!machine.isInAppSwitcher)
    #expect(machine.handle(Self.keyDown()).verdict == .swallow)
  }

  @Test("Focus in another app's panel cancels the hold and forwards ⌘Q there")
  func focusElsewhereForwards() throws {
    let holdID = try startHold()
    let output = machine.handle(.focusElsewhere(holdID: holdID))
    #expect(output.effects == [.cancelHold(holdID: holdID), .forward(keyCode: Self.qKey, includingKeyUp: false)])
    #expect(machine.phase == .idle)
    // The deadline of that hold no longer quits anything.
    #expect(machine.handle(.deadline(holdID: holdID)) == .pass)
    // Repeats still can't reach the frontmost app; the real key up follows the forwarded key down.
    #expect(machine.handle(Self.keyDown(isRepeat: true)) == .swallow)
    #expect(machine.handle(Self.keyUp()) == .pass)
  }

  @Test("A short ⌘Q released before the focus check answered is forwarded whole")
  func shortPressForwardedWhole() throws {
    let holdID = try startHold()
    _ = machine.handle(Self.keyUp())
    let output = machine.handle(.focusElsewhere(holdID: holdID))
    #expect(output.effects == [.forward(keyCode: Self.qKey, includingKeyUp: true)])
    // Only once.
    #expect(machine.handle(.focusElsewhere(holdID: holdID)) == .pass)
  }

  @Test("A focus answer for an older hold does nothing")
  func staleFocusCheckIgnored() throws {
    let first = try startHold()
    _ = machine.handle(Self.keyUp())
    let second = try startHold()
    #expect(machine.handle(.focusElsewhere(holdID: first)) == .pass)
    #expect(machine.phase == .holding(app: Self.terminal, keyCode: Self.qKey, holdID: second))
    // A hold cancelled by ⌘ going up isn't a ⌘Q press to deliver.
    _ = machine.handle(.flagsChanged(flags: []))
    #expect(machine.handle(.focusElsewhere(holdID: second)) == .pass)
  }

  @Test("A fresh press after a missed key up starts a new hold")
  func freshPressRestartsHold() throws {
    let first = try startHold()
    let output = machine.handle(Self.keyDown())
    #expect(output.verdict == .swallow)
    guard case let .startHold(_, second) = output.effects.last else {
      Issue.record("Expected startHold, got \(output.effects)")
      return
    }
    #expect(output.effects.first == .cancelHold(holdID: first))
    #expect(second != first)
    // Only the newest hold can quit.
    #expect(machine.handle(.deadline(holdID: first)) == .pass)
    let quit = machine.handle(.deadline(holdID: second))
    #expect(quit.effects == [.quit(app: Self.terminal, keyCode: Self.qKey, holdID: second)])
  }

  @Test("Reset forgets a hold in progress")
  func resetCancels() throws {
    let holdID = try startHold()
    #expect(machine.handle(.reset).effects == [.cancelHold(holdID: holdID)])
    #expect(machine.handle(.deadline(holdID: holdID)) == .pass)
    #expect(machine.handle(.reset).effects.isEmpty)
  }
}

@Suite("⌘Q guard HUD and app list")
@MainActor
struct QuitGuardHUDTests {
  let start = Date(timeIntervalSinceReferenceDate: 1_000)

  @Test("The ring follows the time since the hold started")
  func progress() {
    #expect(QuitGuardHUDContent.progress(start: start, at: start) == 0)
    #expect(QuitGuardHUDContent.progress(start: start, at: start.addingTimeInterval(0.5)) == 0.5)
    #expect(QuitGuardHUDContent.progress(start: start, at: start.addingTimeInterval(1.5)) == 1)
    #expect(QuitGuardHUDContent.progress(start: start, at: start.addingTimeInterval(-1)) == 0)
  }

  @Test("With Reduce Motion the ring fills in quarter steps")
  func steppedProgress() {
    let stepped = { (seconds: Double) in
      QuitGuardHUDContent.steppedProgress(start: self.start, at: self.start.addingTimeInterval(seconds))
    }
    #expect(stepped(0) == 0)
    #expect(stepped(0.2) == 0)
    #expect(stepped(0.25) == 0.25)
    #expect(stepped(0.6) == 0.5)
    #expect(stepped(0.99) == 1)
    #expect(stepped(2) == 1)
  }

  @Test("The HUD sentence splits around the app name", arguments: [
    ("en", "Hold ⌘Q to quit ", ""),
    ("ru", "Удерживайте ⌘Q, чтобы закрыть «", "»")
  ])
  func sentenceParts(language: String, prefix: String, suffix: String) {
    let parts = QuitGuardHUDText.parts(locale: Locale(identifier: language))
    #expect(parts.prefix == prefix)
    #expect(parts.suffix == suffix)
  }

  @Test("A late hide of an older hold leaves a newer hold's HUD alone")
  func hideMatchesHold() {
    #expect(QuitGuardHUD.shouldHide(requestedHoldID: 2, shownHoldID: 2))
    #expect(!QuitGuardHUD.shouldHide(requestedHoldID: 1, shownHoldID: 2))
    #expect(!QuitGuardHUD.shouldHide(requestedHoldID: 1, shownHoldID: nil))
  }

  @Test("Finder and Multipasta can't be guarded")
  @MainActor
  func unguardableApps() {
    #expect(QuitGuard.unguardableBundleIdentifiers.contains("com.apple.finder"))
    #expect(QuitGuard.unguardableBundleIdentifiers.contains(Bundle.main.bundleIdentifier ?? ""))
  }
}

@Suite("⌘Q guard focus check")
struct QuitGuardFocusTests {
  typealias Process = QuitGuardFocus.FocusedProcess
  let terminalPID: pid_t = 101

  func app(_ path: String, _ bundleIdentifier: String, pid: pid_t = 300, responsible: pid_t? = nil) -> Process {
    Process(
      pid: pid,
      responsiblePID: responsible ?? pid,
      bundleIdentifier: bundleIdentifier,
      bundleURL: URL(fileURLWithPath: path)
    )
  }

  @Test("Focus in the frontmost app itself")
  func sameApp() {
    let focused = app("/System/Applications/Utilities/Terminal.app", "com.apple.Terminal", pid: terminalPID)
    #expect(!QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: focused))
  }

  @Test("Spotlight or Raycast panel counts as elsewhere")
  func otherAppPanel() {
    let spotlight = app("/System/Library/CoreServices/Spotlight.app", "com.apple.Spotlight")
    let raycast = app("/Applications/Raycast.app", "com.raycast.macos")
    #expect(QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: spotlight))
    #expect(QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: raycast))
  }

  @Test("A sandboxed app's Open/Save panel belongs to the app")
  func openSavePanel() {
    let path = "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/"
      + "com.apple.appkit.xpc.openAndSavePanelService.xpc"
    // Known service, even when the responsible process is unknown.
    let unknownResponsible = Process(
      pid: 400,
      responsiblePID: nil,
      bundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService",
      bundleURL: URL(fileURLWithPath: path)
    )
    #expect(!QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: unknownResponsible))
    // Any process macOS holds the frontmost app responsible for.
    let service = app(
      "/Applications/Some.app/Contents/XPCServices/Helper.app", "com.example.helper", responsible: terminalPID
    )
    #expect(!QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: service))
  }

  @Test("When unsure, keep guarding")
  func unsureKeepsGuarding() {
    #expect(!QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: nil))
    let noBundle = Process(pid: 500, responsiblePID: 500, bundleIdentifier: nil, bundleURL: nil)
    #expect(!QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: noBundle))
    let xpc = app("/Library/Something/Service.xpc", "com.example.service")
    #expect(!QuitGuardFocus.isElsewhere(frontmostPID: terminalPID, focused: xpc))
  }
}
