import AppKit
import Carbon
import Sauce
import Settings

// Multipasta: system facts the ⌘Q guard and its settings tab depend on.

extension Settings.PaneIdentifier {
  static let quit = Self("quit")
}

extension Accessibility {
  /// One Accessibility permission covers pasting and the ⌘Q guard.
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Adds Multipasta to the Accessibility list (macOS shows its own prompt once) and opens
  /// System Settings → Privacy & Security → Accessibility.
  static func openSystemSettings() {
    // The value of kAXTrustedCheckOptionPrompt, which Swift 6 can't read as a global var.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }
}

/// What the Quit settings tab shows about the system.
struct QuitGuardSystemStatus: Equatable {
  var isAccessibilityTrusted: Bool
  /// Secure Keyboard Entry is on somewhere: macOS hides key events from the guard.
  var isSecureInputEnabled: Bool
  /// The app that turned Secure Keyboard Entry on, when macOS tells.
  var secureInputAppName: String?

  static var current: QuitGuardSystemStatus {
    let isSecureInputEnabled = IsSecureEventInputEnabled()
    var isAccessibilityTrusted = Accessibility.isTrusted
    #if DEBUG
    // README screenshots only; QuitGuard itself keeps reading Accessibility.isTrusted.
    isAccessibilityTrusted = isAccessibilityTrusted || AppDelegate.readmeScreenshotAccessibilityGranted
    #endif
    return QuitGuardSystemStatus(
      isAccessibilityTrusted: isAccessibilityTrusted,
      isSecureInputEnabled: isSecureInputEnabled,
      secureInputAppName: isSecureInputEnabled ? secureInputOwnerName() : nil
    )
  }

  private static func secureInputOwnerName() -> String? {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
          let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
          pid > 0,
          pid != ProcessInfo.processInfo.processIdentifier else {
      return nil
    }
    return NSRunningApplication(processIdentifier: pid)?.localizedName
  }
}

enum QuitGuardKeyboard {
  /// The key that gives ⌘Q in the current layout, matched the same way as ⌘V in
  /// Clipboard.paste(): layouts that switch to QWERTY with ⌘ use the QWERTY key, layouts
  /// without a Latin Q fall back to it as well.
  static var quitKeyCode: CGKeyCode {
    if KeyboardLayout.current.commandSwitchesToQWERTY {
      return Key.q.QWERTYKeyCode
    }
    return Sauce.shared.keyCode(for: .q)
  }
}

/// Decides whether keyboard focus is really in another app when a hold starts.
/// Any doubt counts as "not elsewhere", so that the guard stays on.
nonisolated enum QuitGuardFocus {
  struct FocusedProcess: Equatable {
    var pid: pid_t
    /// The process macOS holds responsible for `pid` (the app for its XPC services).
    var responsiblePID: pid_t?
    var bundleIdentifier: String?
    var bundleURL: URL?
  }

  /// Out-of-process panels that belong to the app that opened them.
  static let panelServiceBundleIdentifiers: Set<String> = [
    "com.apple.appkit.xpc.openAndSavePanelService",
    "com.apple.appkit.xpc.documentPicker",
    "com.apple.quicklook.QuickLookUIService"
  ]

  static func isElsewhere(frontmostPID: pid_t, focused: FocusedProcess?) -> Bool {
    guard let focused, focused.pid > 0, focused.pid != frontmostPID else {
      return false
    }
    // A sandboxed app's Open/Save panel and other XPC services of the frontmost app.
    if focused.responsiblePID == frontmostPID {
      return false
    }
    guard let bundleIdentifier = focused.bundleIdentifier, let bundleURL = focused.bundleURL else {
      return false
    }
    if panelServiceBundleIdentifiers.contains(bundleIdentifier) {
      return false
    }
    // Spotlight, Raycast, Alfred and the like are apps; anything else is not certain.
    return bundleURL.pathExtension == "app"
  }

  /// Asks Accessibility which process has keyboard focus. Called off the tap thread.
  static func focusedProcess() -> FocusedProcess? {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 0.25)
    var value: CFTypeRef?
    // kAXFocusedApplicationAttribute
    guard AXUIElementCopyAttributeValue(systemWide, "AXFocusedApplication" as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    var pid: pid_t = 0
    // swiftlint:disable:next force_cast
    guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success, pid > 0 else {
      return nil
    }
    let app = NSRunningApplication(processIdentifier: pid)
    return FocusedProcess(
      pid: pid,
      responsiblePID: responsiblePID(for: pid),
      bundleIdentifier: app?.bundleIdentifier,
      bundleURL: app?.bundleURL
    )
  }

  private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

  /// `responsibility_get_pid_responsible_for_pid` from libsystem, looked up at run time:
  /// it is not in the public headers. Nil when it isn't there.
  private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
    // dlopen(nil) searches the app and every library loaded with it.
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
      return nil
    }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
  }()

  private static func responsiblePID(for pid: pid_t) -> pid_t? {
    guard let function = responsiblePIDFunction else {
      return nil
    }
    let responsible = function(pid)
    return responsible > 0 ? responsible : nil
  }
}
