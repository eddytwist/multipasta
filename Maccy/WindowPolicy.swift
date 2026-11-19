import AppKit

// Multipasta: window housekeeping for a menu bar app.
//
// Multipasta stays a menu bar app (LSUIElement) at all times: it has only the popup and Settings,
// so a Dock icon and a place in ⌘Tab while Settings is open aren't worth it (Ed, 19.11.2026).
// What it does: ⌘W closes Settings, and when the last real window closes the keyboard goes back
// to the app that was in front. The regular-app switch below is kept off by
// `switchesActivationPolicy`; apps with a real work window (Aerialist) turn it on.
@MainActor
enum WindowPolicy {
  /// What the policy needs to know about a window.
  struct Window: Equatable {
    var isVisible: Bool
    var isMiniaturized: Bool
    var isTitled: Bool
    var isPanel: Bool
    var isNormalLevel: Bool

    init(isVisible: Bool, isMiniaturized: Bool, isTitled: Bool, isPanel: Bool, isNormalLevel: Bool) {
      self.isVisible = isVisible
      self.isMiniaturized = isMiniaturized
      self.isTitled = isTitled
      self.isPanel = isPanel
      self.isNormalLevel = isNormalLevel
    }

    init(_ window: NSWindow) {
      self.init(
        isVisible: window.isVisible,
        isMiniaturized: window.isMiniaturized,
        isTitled: window.styleMask.contains(.titled),
        isPanel: window is NSPanel,
        isNormalLevel: window.level == .normal
      )
    }

    /// A window the user works in and switches to: shown or minimized, titled, normal level,
    /// not a panel.
    var isReal: Bool {
      (isVisible || isMiniaturized) && isTitled && !isPanel && isNormalLevel
    }
  }

  /// What to do when the policy changes.
  enum Change: Equatable {
    /// Become a regular app and come forward: a regular app doesn't activate by itself.
    case becomeRegular
    /// Go back to the menu bar. `hide` hands the menu bar back to the app that was in front;
    /// otherwise Multipasta's menus stay there until another app is clicked.
    case becomeAccessory(hide: Bool)
  }

  static func wantedPolicy(for windows: [Window]) -> NSApplication.ActivationPolicy {
    windows.contains(where: \.isReal) ? .regular : .accessory
  }

  /// The change from `current` to `wanted`, or nil when there is nothing to do. Hiding would
  /// also hide the popup, so it doesn't happen while the popup is shown.
  static func change(
    from current: NSApplication.ActivationPolicy,
    to wanted: NSApplication.ActivationPolicy,
    isActive: Bool,
    isPopupShown: Bool
  ) -> Change? {
    guard current != wanted else { return nil }
    if wanted == .regular {
      return .becomeRegular
    }
    return .becomeAccessory(hide: isActive && !isPopupShown)
  }

  /// Off for Multipasta: no Dock icon or ⌘Tab while Settings is open.
  static let switchesActivationPolicy = false

  private static var observers: [NSObjectProtocol] = []

  /// Unit tests run inside the app and create windows of their own; keep the policy out of them.
  private static var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  static func observe() {
    guard observers.isEmpty, !isRunningUnitTests else { return }

    let center = NotificationCenter.default
    for name in [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didDeminiaturizeNotification
    ] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { update() }
      })
    }
    // A closing window is still visible while it closes: look again a moment later.
    observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        MainActor.assumeIsolated {
          update()
          handBackKeyboardIfNoWindowLeft()
        }
      }
    })
    update()
  }

  /// True while a real window is open, minimized ones included.
  static var hasOpenWindow: Bool {
    wantedPolicy(for: NSApp.windows.map(Window.init)) == .regular
  }

  // MARK: - ⌘W

  /// SwiftUI's main menu for an app with no window scenes has no File menu, so nothing closed
  /// Settings with ⌘W. This adds File → Close. The item is enabled only while a real window is
  /// key, so in the popup ⌘W does what it did before. SwiftUI may rebuild the menu; every
  /// update puts the item back if it's gone.
  static func installCloseItem() {
    guard let mainMenu = NSApp.mainMenu, closeItem(in: mainMenu) == nil else { return }

    let close = NSMenuItem(
      title: String(localized: "CloseWindow", table: "MultipastaSettings"),
      action: #selector(CloseTarget.closeKeyWindow(_:)),
      keyEquivalent: "w"
    )
    close.keyEquivalentModifierMask = .command
    close.target = CloseTarget.shared

    let file = NSMenu(title: String(localized: "FileMenu", table: "MultipastaSettings"))
    file.addItem(close)
    let fileItem = NSMenuItem(title: file.title, action: nil, keyEquivalent: "")
    fileItem.submenu = file
    mainMenu.insertItem(fileItem, at: min(1, mainMenu.items.count))
  }

  static func closeItem(in mainMenu: NSMenu) -> NSMenuItem? {
    mainMenu.items
      .flatMap { $0.submenu?.items ?? [] }
      .first { $0.action == #selector(CloseTarget.closeKeyWindow(_:)) }
  }

  final class CloseTarget: NSObject, NSMenuItemValidation {
    static let shared = CloseTarget()

    @objc
    func closeKeyWindow(_ sender: Any?) {
      NSApp.keyWindow?.performClose(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
      NSApp.keyWindow.map { Window($0).isReal } ?? false
    }
  }

  // MARK: - Dock

  /// A click on the Dock icon while only minimized windows are open brings one back.
  static func reopen() {
    let windows = NSApp.windows.filter { Window($0).isReal }
    guard !windows.contains(where: \.isVisible), let window = windows.first(where: \.isMiniaturized) else { return }
    window.deminiaturize(nil)
  }

  /// Call it after raising a window with `orderFrontRegardless()`: a window raised without
  /// activation never becomes key, so no notification comes.
  static func update() {
    guard !observers.isEmpty else { return }
    installCloseItem()
    guard switchesActivationPolicy else { return }

    let wanted = wantedPolicy(for: NSApp.windows.map(Window.init))
    let change = change(
      from: NSApp.activationPolicy(),
      to: wanted,
      isActive: NSApp.isActive,
      isPopupShown: AppState.shared.appDelegate?.panel?.isPresented == true
    )
    guard let change else { return }

    NSApp.setActivationPolicy(wanted)
    switch change {
    case .becomeRegular:
      NSApp.activate()
    case .becomeAccessory(let hide):
      if hide {
        NSApp.hide(nil)
      }
    }
  }

  /// Settings comes forward when opened (AppState.openPreferences); once the last titled window
  /// closes, give the keyboard and the menu bar back to the app that was in front. Not while the
  /// popup is shown: hiding would hide it too.
  static func handBackKeyboardIfNoWindowLeft() {
    guard !switchesActivationPolicy, NSApp.isActive,
          AppState.shared.appDelegate?.panel?.isPresented != true,
          !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
    NSApp.hide(nil)
  }
}
