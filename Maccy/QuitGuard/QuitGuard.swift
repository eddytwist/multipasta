import AppKit
import Defaults
import Sauce

// Multipasta: the ⌘Q guard.
//
// In the apps from Settings → Quit (`Defaults[.quitGuardApps]`, bundle identifiers) ⌘Q does
// not quit at once: a HUD asks to hold ⌘Q, and the app quits after one second of holding.
// An empty list means the guard is off; the event tap exists only while the list is not empty
// and Accessibility is granted.
@MainActor
final class QuitGuard {
  static let shared = QuitGuard()

  /// Apps that can't be guarded: Finder has no Quit command, and ⌘Q in Multipasta itself is
  /// handled by its own popup.
  static var unguardableBundleIdentifiers: Set<String> {
    ["com.apple.finder", Bundle.main.bundleIdentifier ?? "com.eddytwist.Multipasta"]
  }

  private let hud: QuitGuardHUD
  private let eventTap: QuitGuardEventTap

  private var isStarted = false
  private var guardedApps: [String] = []
  private var lastStartFailed = false
  private var pollTimer: Timer?
  private var defaultsTask: Task<Void, Never>?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  private init() {
    let hud = QuitGuardHUD()
    self.hud = hud
    eventTap = QuitGuardEventTap(
      onShowHUD: { app, start, holdID in hud.show(app: app, start: start, holdID: holdID) },
      onHideHUD: { reason, holdID in hud.hide(holdID: holdID, animated: reason == .cancelled) },
      onPermissionLost: { QuitGuard.shared.reconcile() }
    )
  }

  /// Unit tests run inside the app; keep the guard out of them.
  private static var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  func start() {
    guard !isStarted, !Self.isRunningUnitTests else {
      return
    }
    isStarted = true

    eventTap.setQuitKeyCode(QuitGuardKeyboard.quitKeyCode)
    updateFrontmostApp(NSWorkspace.shared.frontmostApplication)

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    observe(workspaceCenter, NSWorkspace.didActivateApplicationNotification) { notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated { QuitGuard.shared.updateFrontmostApp(app) }
    }
    // The popup is a non-activating panel: while it is key, ⌘Q belongs to Multipasta.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observe(NotificationCenter.default, name) { _ in
        // On resign, the next key window (if any) is known only after this notification.
        DispatchQueue.main.async {
          QuitGuard.shared.eventTap.setOwnWindowIsKey(NSApp.keyWindow?.isVisible == true)
        }
      }
    }
    observe(NotificationCenter.default, .SauceSelectedKeyboardKeyCodesChanged) { _ in
      MainActor.assumeIsolated { QuitGuard.shared.eventTap.setQuitKeyCode(QuitGuardKeyboard.quitKeyCode) }
    }
    // Posted when the Accessibility list changes; the new state is readable a moment later.
    observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.accessibility.api")) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        QuitGuard.shared.reconcile()
      }
    }

    defaultsTask = Task { [weak self] in
      for await apps in Defaults.updates(.quitGuardApps) {
        self?.guardedApps = apps
        self?.reconcile()
      }
    }
  }

  /// Starts or stops the event tap to match the list and the Accessibility permission.
  func reconcile() {
    let guarded = Set(guardedApps).subtracting(Self.unguardableBundleIdentifiers)
    eventTap.setGuardedBundleIdentifiers(guarded)

    let shouldRun = !guarded.isEmpty && Accessibility.isTrusted
    if shouldRun && !eventTap.isRunning {
      let started = eventTap.start()
      if !started && !lastStartFailed {
        QuitGuardEventTap.logger.error("⌘Q guard is off: the event tap could not be created for \(guarded.sorted())")
      }
      lastStartFailed = !started
    } else if !shouldRun && eventTap.isRunning {
      eventTap.stop()
      hud.hide(animated: false)
      lastStartFailed = false
    }

    // Accessibility can be granted or revoked at any time; check it while the guard is wanted.
    if guarded.isEmpty {
      pollTimer?.invalidate()
      pollTimer = nil
    } else if pollTimer == nil {
      pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        MainActor.assumeIsolated { QuitGuard.shared.reconcile() }
      }
    }
  }

  private func updateFrontmostApp(_ app: NSRunningApplication?) {
    guard let app, let bundleIdentifier = app.bundleIdentifier else {
      eventTap.setFrontmostApp(nil)
      return
    }
    eventTap.setFrontmostApp(
      QuitGuardStateMachine.App(
        bundleIdentifier: bundleIdentifier,
        processIdentifier: app.processIdentifier,
        name: app.localizedName ?? bundleIdentifier
      )
    )
  }

  private func observe(
    _ center: NotificationCenter,
    _ name: Notification.Name,
    using block: @escaping @Sendable (Notification) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main, using: block)
    observers.append((center, token))
  }
}
