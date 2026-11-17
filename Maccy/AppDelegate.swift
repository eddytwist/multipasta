import Defaults
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  nonisolated static let isTesting = CommandLine.arguments.contains("enable-testing")
  #if DEBUG
  /// Set by the README screenshot test (`-MultipastaTestAppearance dark|light`, testing only).
  nonisolated static let readmeScreenshotAppearance: String? = isTesting
    ? UserDefaults.standard.string(forKey: "MultipastaTestAppearance")
    : nil
  /// Set by the README screenshot test (`-MultipastaTestAccessibilityGranted YES`, testing only):
  /// the Quit tab shows Accessibility as granted. Only the display; the ⌘Q guard still checks
  /// the real permission.
  nonisolated static let readmeScreenshotAccessibilityGranted: Bool = isTesting
    && UserDefaults.standard.bool(forKey: "MultipastaTestAccessibilityGranted")
  #endif
  var panel: FloatingPanel<ContentView>!

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Self.statusImage(Defaults[.menuIcon].image)
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  // Base accessibility label for the status item; kept separate from the optional
  // dynamic `title` (recent copy text) so VoiceOver always announces something
  // meaningful even when that preference is off or the app is disabled.
  private func updateStatusItemAccessibilityLabel() {
    var accessibilityLabel = NSLocalizedString("status_item_accessibility_label", comment: "")
    if isStatusItemDisabled {
      accessibilityLabel += " — \(NSLocalizedString("status_item_disabled_accessibility_suffix", comment: ""))"
    }
    statusItem.button?.setAccessibilityLabel(accessibilityLabel)
  }

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    // Multipasta: before anything creates the history store, which tells a new install from an
    // update for the sound settings (Maccy/Sounds/SoundPlayer.swift).
    let storeExisted = FileManager.default.fileExists(atPath: Storage.fileURL.path(percentEncoded: false))

    #if DEBUG
    if Self.isTesting {
      // Start from a clean slate for the isolated testing preferences.
      UserDefaults.standard.removePersistentDomain(forName: Defaults.Keys.testingSuiteName)
      // Multipasta pastes on Enter by default. UI tests select items by Enter or click,
      // so keep Maccy's copy-only behaviour there instead of sending ⌘V to the frontmost app.
      // This writes to the isolated testing suite only, not to the user's defaults.
      Defaults[.pasteByDefault] = false
      // No feedback sounds while tests copy and paste (isolated testing suite only).
      Defaults[.playCopySound] = false
      Defaults[.playListSound] = false
      // The README screenshot test picks the appearance; `-AppleInterfaceStyle` no longer
      // changes an app's appearance.
      if let appearance = Self.readmeScreenshotAppearance {
        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
      }
    }
    #endif

    Task {
      #if DEBUG
      // Tests use an in-memory store: the user's store file says nothing about them.
      await SoundSettingsMigration.run(storeExisted: storeExisted && !Self.isTesting)
      #else
      await SoundSettingsMigration.run(storeExisted: storeExisted)
      #endif
    }

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { History.shared.add($0) }
    Clipboard.shared.start()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = Self.statusImage(value.image)
      }
    }

    // Multipasta: a dot on the icon while an update waits (Maccy/SoftwareUpdater.swift).
    observeUpdateDot()

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    updateStatusItemAccessibilityLabel()

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "com.eddytwist.Multipasta",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }

    // Multipasta: hold ⌘Q to quit the apps listed in Settings → Quit.
    QuitGuard.shared.start()

    // Multipasta: the add-to-list shortcut (Maccy/ListCopy).
    ListCopy.shared.start()

    // Multipasta: in-app updates (Maccy/SoftwareUpdater.swift). Tests stay offline, and a Debug
    // build doesn't offer to replace itself with a release unless asked (`-MultipastaUpdater YES`).
    #if DEBUG
    let startsUpdater = !Self.isTesting && UserDefaults.standard.bool(forKey: "MultipastaUpdater")
    #else
    let startsUpdater = !Self.isTesting
    #endif
    if startsUpdater {
      SoftwareUpdater.shared.start()
    }

    // Multipasta: offer once to import the clipboard history of upstream Maccy.
    if !Self.isTesting {
      Task {
        try? await Task.sleep(for: .seconds(1))
        MaccyImporter.offerImportIfNeeded()
      }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Multipasta: don't leave a lazily provided list behind on the clipboard.
    MainActor.assumeIsolated {
      ListCopy.shared.applicationWillTerminate()
    }

    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  private func ensureMigration(key: String, _ action: () -> Void) {
    if Defaults[.migrations][key] != true {
      action()
      Defaults[.migrations][key] = true
    }
  }

  @MainActor
  private func migrateUserDefaults() {
    ensureMigration(key: "2024-07-01-version-2") {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")
    }

    ensureMigration(key: "2025-07-04-add-jpeg-heic") {
      var types = Defaults[.enabledPasteboardTypes]
      if !types.isDisjoint(with: StorageType.images.types) {
        types.formUnion(StorageType.images.types)
      }
      Defaults[.enabledPasteboardTypes] = types
    }

    ensureMigration(key: "2026-08-12-cleanup-orphaned-history-item-contents") {
      _ = try? Storage.shared.cleanupOrphanedContents()
    }

    ensureMigration(key: "2026-08-31-sanitize-history-item-titles") {
      _ = try? Storage.shared.sanitizeTitles()
    }

    ensureMigration(key: "2026-09-15-remove-unpersistable-contents") {
      _ = try? Storage.shared.removeUnpersistableContents()
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    let modifierFlags = (NSApp.currentEvent?.modifierFlags ?? [])
      .union(NSEvent.modifierFlags)
      .intersection(.deviceIndependentFlagsMask)

    if modifierFlags.contains(.option) {
      Defaults[.ignoreEvents].toggle()

      if modifierFlags.contains(.shift) {
        Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
      }

      return
    }

    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  // MARK: - Multipasta: update dot

  private func observeUpdateDot() {
    withObservationTracking {
      _ = SoftwareUpdater.shared.pendingVersion
    } onChange: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        statusItem.button?.image = Self.statusImage(Defaults[.menuIcon].image)
        observeUpdateDot()
      }
    }
  }

  /// The menu icon, with a small dot in its top right corner while an update waits.
  @MainActor
  static func statusImage(_ icon: NSImage) -> NSImage {
    guard SoftwareUpdater.shared.pendingVersion != nil else { return icon }
    let size = icon.size
    let badged = NSImage(size: size, flipped: false) { rect in
      icon.draw(in: rect)
      let diameter = max(4, size.height * 0.3)
      let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
      NSGraphicsContext.current?.compositingOperation = .clear
      NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      NSColor.black.setFill()
      NSBezierPath(ovalIn: dot).fill()
      return true
    }
    badged.isTemplate = icon.isTemplate
    badged.accessibilityDescription = icon.accessibilityDescription
    return badged
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin, .togglePreview]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
            names.contains(name) else { return }
      MainActor.assumeIsolated {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}
