import CoreGraphics
import Foundation

// Multipasta: decision logic of the ⌘Q guard.
//
// Kept free of event taps, timers and windows so it can be unit-tested. The event tap feeds
// keyboard events into `handle(_:)`, lets each event pass or swallows it according to the
// returned verdict, and performs the returned effects (show/hide the HUD, quit the app).
nonisolated struct QuitGuardStateMachine {
  struct App: Equatable {
    var bundleIdentifier: String
    var processIdentifier: pid_t
    var name: String
  }

  enum Event: Equatable {
    /// `isQuitKey` is true for the key that gives ⌘Q in the current keyboard layout.
    /// `isMarked` is true for the ⌘Q that the guard posts itself.
    /// `app` is the app that gets the keys: the frontmost app, or nil when the keys go
    /// elsewhere (Multipasta's own popup or settings, no frontmost app).
    case keyDown(keyCode: CGKeyCode, isQuitKey: Bool, flags: CGEventFlags, isRepeat: Bool, isMarked: Bool, app: App?)
    case keyUp(keyCode: CGKeyCode, isMarked: Bool)
    case flagsChanged(flags: CGEventFlags)
    /// The hold timer of the hold with `holdID` has fired.
    case deadline(holdID: UInt64)
    /// Keyboard focus turned out to be in another app's panel (Spotlight, Raycast, Alfred…)
    /// rather than in the frontmost app when the hold with `holdID` started.
    case focusElsewhere(holdID: UInt64)
    /// Another app became frontmost.
    case frontmostAppChanged
    /// The tap was disabled or restarted: forget any hold in progress.
    case reset
  }

  enum Verdict: Equatable {
    case pass
    case swallow
  }

  enum Effect: Equatable {
    /// Show the HUD and start the hold timer that delivers `.deadline(holdID:)`.
    case startHold(app: App, holdID: UInt64)
    /// Hide the HUD of the hold; its pending deadline is ignored.
    case cancelHold(holdID: UInt64)
    /// Hide the HUD of the hold and quit `app` by sending it ⌘Q with `keyCode`.
    case quit(app: App, keyCode: CGKeyCode, holdID: UInt64)
    /// Deliver the swallowed ⌘Q after all, to wherever keyboard focus is: the key down only
    /// while Q is still held (the real key up follows), or the whole press when Q was
    /// released before the focus check answered.
    case forward(keyCode: CGKeyCode, includingKeyUp: Bool)
  }

  enum Phase: Equatable {
    case idle
    case holding(app: App, keyCode: CGKeyCode, holdID: UInt64)
    /// Swallow the auto-repeats and the key up of `keyCode` until it is released, whatever the
    /// modifiers are by then. Entered when a hold ends while the key is still down: ⌘ released
    /// or another modifier added (repeats would type "q" or become ⌘⇧Q, Log Out), another key
    /// pressed, or the app asked to quit.
    case suppressing(keyCode: CGKeyCode)
  }

  struct Output: Equatable {
    var verdict: Verdict
    var effects: [Effect] = []

    static let pass = Output(verdict: .pass)
    static let swallow = Output(verdict: .swallow)
  }

  /// How long ⌘Q has to be held to quit. Fixed by design, no setting.
  static let holdDuration: TimeInterval = 1

  /// ⌘Tab opens the app switcher; ⌘Q in it quits the selected app and must reach the Dock
  /// untouched. (⌘` only moves through the switcher once it is open, and on its own it cycles
  /// the windows of the frontmost app, so it doesn't open the switcher here.)
  static let tabKeyCode: CGKeyCode = 48 // kVK_Tab
  /// Esc closes the app switcher without switching.
  static let escapeKeyCode: CGKeyCode = 53 // kVK_Escape

  var guardedBundleIdentifiers: Set<String> = []
  private(set) var phase: Phase = .idle
  /// ⌘Tab was pressed during the current ⌘ press and not dismissed: the app switcher is open.
  private(set) var isInAppSwitcher = false
  private var lastHoldID: UInt64 = 0
  /// The hold whose Q was released while its focus check was still running.
  private var releasedBeforeFocusCheck: (holdID: UInt64, keyCode: CGKeyCode)?

  init(guardedBundleIdentifiers: Set<String> = []) {
    self.guardedBundleIdentifiers = guardedBundleIdentifiers
  }

  /// Command alone: Shift, Option or Control turn ⌘Q into a different shortcut.
  /// Caps Lock, Fn and the device-dependent bits are ignored.
  static func isCommandOnly(_ flags: CGEventFlags) -> Bool {
    flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand
  }

  mutating func handle(_ event: Event) -> Output {
    switch event {
    case let .keyDown(keyCode, isQuitKey, flags, isRepeat, isMarked, app):
      return keyDown(
        keyCode: keyCode, isQuitKey: isQuitKey, flags: flags, isRepeat: isRepeat, isMarked: isMarked, app: app
      )
    case let .keyUp(keyCode, isMarked):
      return keyUp(keyCode: keyCode, isMarked: isMarked)
    case let .flagsChanged(flags):
      if !flags.contains(.maskCommand) {
        isInAppSwitcher = false
      }
      if case let .holding(_, keyCode, holdID) = phase, !Self.isCommandOnly(flags) {
        phase = .suppressing(keyCode: keyCode)
        return Output(verdict: .pass, effects: [.cancelHold(holdID: holdID)])
      }
      return .pass
    case let .deadline(holdID):
      if case let .holding(app, keyCode, currentID) = phase, currentID == holdID {
        phase = .suppressing(keyCode: keyCode)
        return Output(verdict: .pass, effects: [.quit(app: app, keyCode: keyCode, holdID: holdID)])
      }
      return .pass
    case let .focusElsewhere(holdID):
      if case let .holding(_, keyCode, currentID) = phase, currentID == holdID {
        // The key down goes where it was meant to; the real key up will follow it.
        phase = .idle
        return Output(
          verdict: .pass,
          effects: [.cancelHold(holdID: holdID), .forward(keyCode: keyCode, includingKeyUp: false)]
        )
      }
      if let released = releasedBeforeFocusCheck, released.holdID == holdID {
        // A short ⌘Q in Spotlight or Raycast: Q was already up when the answer came.
        releasedBeforeFocusCheck = nil
        return Output(verdict: .pass, effects: [.forward(keyCode: released.keyCode, includingKeyUp: true)])
      }
      return .pass
    case .frontmostAppChanged:
      isInAppSwitcher = false
      return .pass
    case .reset:
      var effects: [Effect] = []
      if case let .holding(_, _, holdID) = phase {
        effects.append(.cancelHold(holdID: holdID))
      }
      phase = .idle
      isInAppSwitcher = false
      releasedBeforeFocusCheck = nil
      return Output(verdict: .pass, effects: effects)
    }
  }

  // swiftlint:disable:next function_parameter_count cyclomatic_complexity
  private mutating func keyDown(
    keyCode: CGKeyCode,
    isQuitKey: Bool,
    flags: CGEventFlags,
    isRepeat: Bool,
    isMarked: Bool,
    app: App?
  ) -> Output {
    // The guard's own ⌘Q goes through untouched.
    if isMarked {
      return .pass
    }

    if flags.contains(.maskCommand) && keyCode == Self.tabKeyCode {
      isInAppSwitcher = true
    } else if keyCode == Self.escapeKeyCode {
      isInAppSwitcher = false
    }

    var effects: [Effect] = []
    switch phase {
    case let .holding(_, heldKeyCode, holdID):
      if keyCode == heldKeyCode {
        if isRepeat {
          return .swallow
        }
        // A fresh press of Q after a key up we never saw: start over.
        phase = .idle
        effects.append(.cancelHold(holdID: holdID))
      } else {
        // Another key: the hold is over, but Q is still down.
        phase = .suppressing(keyCode: heldKeyCode)
        return Output(verdict: .pass, effects: [.cancelHold(holdID: holdID)])
      }
    case let .suppressing(heldKeyCode):
      guard keyCode == heldKeyCode else {
        return .pass
      }
      if isRepeat {
        return .swallow
      }
      // A fresh press after a key up we never saw.
      phase = .idle
    case .idle:
      break
    }

    guard isQuitKey,
          Self.isCommandOnly(flags),
          !isInAppSwitcher,
          let app,
          guardedBundleIdentifiers.contains(app.bundleIdentifier) else {
      return Output(verdict: .pass, effects: effects)
    }

    // A repeat without a hold (the tap started while Q was down, or focus was elsewhere):
    // passing it would quit the app at once.
    if isRepeat {
      return Output(verdict: .swallow, effects: effects)
    }

    lastHoldID &+= 1
    releasedBeforeFocusCheck = nil
    phase = .holding(app: app, keyCode: keyCode, holdID: lastHoldID)
    effects.append(.startHold(app: app, holdID: lastHoldID))
    return Output(verdict: .swallow, effects: effects)
  }

  private mutating func keyUp(keyCode: CGKeyCode, isMarked: Bool) -> Output {
    if isMarked {
      return .pass
    }

    switch phase {
    case let .holding(_, heldKeyCode, holdID) where heldKeyCode == keyCode:
      // The app never saw the key down, so it doesn't get the key up either.
      phase = .idle
      releasedBeforeFocusCheck = (holdID, keyCode)
      return Output(verdict: .swallow, effects: [.cancelHold(holdID: holdID)])
    case let .suppressing(heldKeyCode) where heldKeyCode == keyCode:
      phase = .idle
      return .swallow
    default:
      return .pass
    }
  }
}
