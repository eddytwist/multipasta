import AppKit
import CoreGraphics
import Logging

// Multipasta: the active event tap of the ⌘Q guard.
//
// The tap runs on its own thread so that a busy main thread never delays typing in other
// apps or gets the tap disabled by a timeout. The callback only reads a few event fields and
// runs the state machine under a lock; the HUD is updated on the main thread.
nonisolated final class QuitGuardEventTap: @unchecked Sendable {
  typealias App = QuitGuardStateMachine.App

  enum HideReason {
    case cancelled
    case quitting
  }

  /// Written to `eventSourceUserData` of the ⌘Q events the guard posts itself, so that the
  /// tap lets them through. "MPQG" in ASCII.
  static let marker: Int64 = 0x4D50_5147

  static let logger = Logger(label: "com.eddytwist.Multipasta.QuitGuard")

  // Called on the main thread.
  private let onShowHUD: @MainActor @Sendable (App, Date, UInt64) -> Void
  private let onHideHUD: @MainActor @Sendable (HideReason, UInt64) -> Void
  /// macOS disabled the tap and Accessibility is no longer granted.
  private let onPermissionLost: @MainActor @Sendable () -> Void

  private let lock = NSLock()
  private var machine = QuitGuardStateMachine()
  private var frontmostApp: App?
  private var ownWindowIsKey = false
  private var quitKeyCode = CGKeyCode(12) // kVK_ANSI_Q

  private var machPort: CFMachPort?
  private var runLoop: CFRunLoop?

  init(
    onShowHUD: @escaping @MainActor @Sendable (_ app: App, _ start: Date, _ holdID: UInt64) -> Void,
    onHideHUD: @escaping @MainActor @Sendable (_ reason: HideReason, _ holdID: UInt64) -> Void,
    onPermissionLost: @escaping @MainActor @Sendable () -> Void
  ) {
    self.onShowHUD = onShowHUD
    self.onHideHUD = onHideHUD
    self.onPermissionLost = onPermissionLost
  }

  var isRunning: Bool {
    lock.withLock { machPort != nil }
  }

  // MARK: - State shared with the main thread

  func setGuardedBundleIdentifiers(_ bundleIdentifiers: Set<String>) {
    lock.withLock { machine.guardedBundleIdentifiers = bundleIdentifiers }
  }

  func setFrontmostApp(_ app: App?) {
    let changed = lock.withLock {
      let changed = frontmostApp?.processIdentifier != app?.processIdentifier
      frontmostApp = app
      return changed
    }
    if changed {
      feed(.frontmostAppChanged)
    }
  }

  /// Multipasta's popup is a non-activating panel: while it (or any Multipasta window) is
  /// key, the keys go to Multipasta even though another app is frontmost.
  func setOwnWindowIsKey(_ isKey: Bool) {
    lock.withLock { ownWindowIsKey = isKey }
  }

  func setQuitKeyCode(_ keyCode: CGKeyCode) {
    lock.withLock { quitKeyCode = keyCode }
  }

  // MARK: - Lifecycle

  /// Creates the tap and starts its thread. Returns false when macOS refuses to create it
  /// (usually because Accessibility is not granted).
  func start() -> Bool {
    if isRunning {
      return true
    }

    let mask = (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: { _, type, event, refcon in
        guard let refcon else {
          return Unmanaged.passUnretained(event)
        }
        let tap = Unmanaged<QuitGuardEventTap>.fromOpaque(refcon).takeUnretainedValue()
        return tap.handle(type: type, event: event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      Self.logger.error(
        "Failed to create the ⌘Q guard event tap (AXIsProcessTrusted: \(AXIsProcessTrusted()))"
      )
      return false
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      Self.logger.error("Failed to create a run loop source for the ⌘Q guard event tap")
      CFMachPortInvalidate(port)
      return false
    }

    let ready = DispatchSemaphore(value: 0)
    // Handed over to the tap thread, which is the only one that uses it from here on.
    nonisolated(unsafe) let threadSource = source
    let thread = Thread { [weak self] in
      let runLoop = CFRunLoopGetCurrent()
      CFRunLoopAddSource(runLoop, threadSource, .commonModes)
      self?.lock.withLock { self?.runLoop = runLoop }
      ready.signal()
      CFRunLoopRun()
    }
    thread.name = "com.eddytwist.Multipasta.QuitGuard"
    thread.qualityOfService = .userInteractive

    lock.withLock {
      machPort = port
      _ = machine.handle(.reset)
    }
    thread.start()
    ready.wait()
    CGEvent.tapEnable(tap: port, enable: true)
    return true
  }

  func stop() {
    let (port, runLoop) = lock.withLock {
      let values = (machPort, self.runLoop)
      machPort = nil
      self.runLoop = nil
      _ = machine.handle(.reset)
      return values
    }
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    if let runLoop {
      CFRunLoopStop(runLoop)
    }
  }

  // MARK: - Tap callback (tap thread)

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    let stateEvent: QuitGuardStateMachine.Event
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      // Re-enable only while Accessibility is granted. Without it the tap stays off (events
      // flow untouched) and the main thread tears it down.
      if AXIsProcessTrusted() {
        if let port = lock.withLock({ machPort }) {
          CGEvent.tapEnable(tap: port, enable: true)
        }
      } else {
        let permissionLost = onPermissionLost
        DispatchQueue.main.async { permissionLost() }
      }
      stateEvent = .reset
    case .keyDown:
      let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
      let (quitKeyCode, app) = lock.withLock { (self.quitKeyCode, ownWindowIsKey ? nil : frontmostApp) }
      stateEvent = .keyDown(
        keyCode: keyCode,
        isQuitKey: keyCode == quitKeyCode,
        flags: event.flags,
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        isMarked: event.getIntegerValueField(.eventSourceUserData) == Self.marker,
        app: app
      )
    case .keyUp:
      stateEvent = .keyUp(
        keyCode: CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
        isMarked: event.getIntegerValueField(.eventSourceUserData) == Self.marker
      )
    case .flagsChanged:
      stateEvent = .flagsChanged(flags: event.flags)
    default:
      return Unmanaged.passUnretained(event)
    }

    let output = lock.withLock { machine.handle(stateEvent) }
    perform(output.effects)
    return output.verdict == .swallow ? nil : Unmanaged.passUnretained(event)
  }

  private func feed(_ event: QuitGuardStateMachine.Event) {
    let output = lock.withLock { machine.handle(event) }
    perform(output.effects)
  }

  private func perform(_ effects: [QuitGuardStateMachine.Effect]) {
    for effect in effects {
      switch effect {
      case let .startHold(app, holdID):
        let start = Date()
        let queue = DispatchQueue.global(qos: .userInteractive)
        queue.asyncAfter(deadline: .now() + QuitGuardStateMachine.holdDuration) { [weak self] in
          self?.feed(.deadline(holdID: holdID))
        }
        // Off the tap thread: the Accessibility query talks to another process.
        queue.async { [weak self] in
          let focused = QuitGuardFocus.focusedProcess()
          if QuitGuardFocus.isElsewhere(frontmostPID: app.processIdentifier, focused: focused) {
            self?.feed(.focusElsewhere(holdID: holdID))
          } else {
            self?.showHUDIfStillHolding(app: app, holdID: holdID, start: start)
          }
        }
      case let .cancelHold(holdID):
        let hide = onHideHUD
        DispatchQueue.main.async { hide(.cancelled, holdID) }
      case let .quit(app, keyCode, holdID):
        let hide = onHideHUD
        DispatchQueue.main.async { hide(.quitting, holdID) }
        quit(app, keyCode: keyCode)
      case let .forward(keyCode, includingKeyUp):
        forward(keyCode: keyCode, includingKeyUp: includingKeyUp)
      }
    }
  }

  /// Checking the phase and queueing the HUD under one lock keeps the order with a cancel:
  /// either the hold is already over and nothing is shown, or the show is queued before the
  /// cancel's hide.
  private func showHUDIfStillHolding(app: App, holdID: UInt64, start: Date) {
    lock.withLock {
      guard case let .holding(_, _, currentID) = machine.phase, currentID == holdID else {
        return
      }
      let show = onShowHUD
      DispatchQueue.main.async { show(app, start, holdID) }
    }
  }

  // MARK: - Posting

  private static func commandEvents(keyCode: CGKeyCode) -> (down: CGEvent, up: CGEvent)? {
    let source = CGEventSource(stateID: .privateState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
      return nil
    }
    // 0x8 marks the left ⌘ key as pressed, as a real keyboard does.
    // See https://github.com/TermiT/Flycut/pull/18 and Clipboard.paste().
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
    for event in [down, up] {
      event.flags = flags
      event.setIntegerValueField(.eventSourceUserData, value: marker)
    }
    return (down, up)
  }

  /// Quits the app the normal way: sends ⌘Q straight to its process, so the app handles it
  /// like a menu shortcut and its own "Quit?" confirmation still works, and no other app
  /// can get it if the front app changed meanwhile. Falls back to `terminate()` only when the
  /// events can't be created.
  private func quit(_ app: App, keyCode: CGKeyCode) {
    guard let events = Self.commandEvents(keyCode: keyCode) else {
      Self.logger.error("Failed to create the ⌘Q events for \(app.bundleIdentifier), terminating it instead")
      let terminated = NSRunningApplication(processIdentifier: app.processIdentifier)?.terminate() ?? false
      if !terminated {
        Self.logger.error("Failed to terminate \(app.bundleIdentifier) (pid \(app.processIdentifier))")
      }
      return
    }
    events.down.postToPid(app.processIdentifier)
    events.up.postToPid(app.processIdentifier)
  }

  /// Sends the swallowed ⌘Q on to wherever keyboard focus is. While Q is still held only the
  /// key down is sent and the real key up passes the tap on its own.
  private func forward(keyCode: CGKeyCode, includingKeyUp: Bool) {
    guard let events = Self.commandEvents(keyCode: keyCode) else {
      Self.logger.error("Failed to create the ⌘Q events to forward to the focused panel")
      return
    }
    events.down.post(tap: .cgSessionEventTap)
    if includingKeyUp {
      events.up.post(tap: .cgSessionEventTap)
    }
  }
}
