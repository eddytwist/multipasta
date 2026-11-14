import AppKit
import Defaults
import SwiftUI
import Testing
@testable import Maccy

// Debug-only visual harness for the Multipasta UI. It renders the popup, the settings
// tabs and the ⌘Q guard HUD offscreen to PNG files so they can be reviewed without opening the app.
//
// Skipped unless MULTIPASTA_SNAPSHOTS is set. With xcodebuild, pass it to the test runner as
//   TEST_RUNNER_MULTIPASTA_SNAPSHOTS=1 xcodebuild … -only-testing:MaccyTests/SnapshotTests test
// Output goes to MULTIPASTA_SNAPSHOTS_DIR (TEST_RUNNER_MULTIPASTA_SNAPSHOTS_DIR) or to
// build/snapshots next to the project.
//
// Note: offscreen rendering does not capture the popup's and the HUD's glass / visual-effect
// material, so they are drawn on the window background colour instead.
private let snapshotsEnabled = ProcessInfo.processInfo.environment["MULTIPASTA_SNAPSHOTS"] != nil

extension SharedStateTests {
  @MainActor
  @Suite(.enabled(if: snapshotsEnabled, "Set MULTIPASTA_SNAPSHOTS to render UI snapshots"))
  final class SnapshotTests {
    let savedPinTo = Defaults[.pinTo]
    let savedPinOrder = Defaults[.pinOrder]
    let savedShowFooter = Defaults[.showFooter]
    let savedIgnoredApps = Defaults[.ignoredApps]
    let savedOpenPreviewAutomatically = Defaults[.openPreviewAutomatically]
    let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
    let savedSize = Defaults[.size]
    let savedQuitGuardApps = Defaults[.quitGuardApps]

    private var outputDirectory: URL {
      if let path = ProcessInfo.processInfo.environment["MULTIPASTA_SNAPSHOTS_DIR"] {
        return URL(fileURLWithPath: path)
      }
      // MaccyTests/SnapshotTests.swift -> <project>/build/snapshots
      return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "build/snapshots")
    }

    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    init() {
      History.shared.clearAll()
      Defaults[.pinTo] = .top
      Defaults[.pinOrder] = PinOrder()
      Defaults[.showFooter] = true
      Defaults[.openPreviewAutomatically] = false
    }

    deinit {
      MainActor.assumeIsolated {
        History.shared.clearAll()
        AppState.shared.history.searchQuery = ""
      }
      Defaults[.pinTo] = savedPinTo
      Defaults[.pinOrder] = savedPinOrder
      Defaults[.showFooter] = savedShowFooter
      Defaults[.ignoredApps] = savedIgnoredApps
      Defaults[.openPreviewAutomatically] = savedOpenPreviewAutomatically
      Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
      Defaults[.size] = savedSize
      Defaults[.quitGuardApps] = savedQuitGuardApps
    }

    @Test("Popup with items")
    func popupWithItems() async throws {
      let values = [
        "https://github.com/p0deje/Maccy",
        "npm run build && npm test",
        "Screenshot 2026-11-14 at 12.41.08",
        "Best regards,\nEd"
      ]
      for value in values {
        History.shared.add(Self.historyItem(value))
      }
      let pinned = try #require(History.shared.items.first { $0.text.hasPrefix("Best regards") })
      History.shared.togglePin(pinned)

      try await renderPopup(name: "popup-items", height: 290) {
        AppState.shared.navigator.select(item: History.shared.firstUnpinnedItem)
      }
    }

    @Test("Popup with empty history")
    func popupEmpty() async throws {
      try await renderPopup(name: "popup-empty", height: 200)
    }

    @Test("Popup with no search results")
    func popupNoMatches() async throws {
      History.shared.add(Self.historyItem("npm run build && npm test"))
      try await renderPopup(name: "popup-no-matches", height: 200) {
        AppState.shared.history.searchQuery = "zzzz"
      }
    }

    @Test("Settings tabs and Advanced sheet")
    func settings() async throws {
      Defaults[.openPreviewAutomatically] = savedOpenPreviewAutomatically
      Defaults[.ignoredApps] = ["com.apple.Terminal", "com.apple.keychainaccess", "com.example.NotInstalled"]
      for locale in ["en", "ru"] {
        try await render(name: "settings-general-\(locale)", locale: locale) { GeneralSettingsTab() }
        try await render(name: "settings-history-\(locale)", locale: locale) { HistorySettingsTab() }
        try await render(name: "settings-advanced-\(locale)", locale: locale, scrollPages: 6) {
          AdvancedSettingsSheet()
        }
      }

      // "Save only from these apps" mode and a history size outside the presets.
      Defaults[.ignoreAllAppsExceptListed] = true
      Defaults[.size] = 237
      for locale in ["en", "ru"] {
        try await render(name: "settings-history-only-listed-\(locale)", locale: locale) { HistorySettingsTab() }
      }
      Defaults[.ignoredApps] = []
      try await render(name: "settings-history-only-listed-empty-en", locale: "en") { HistorySettingsTab() }
    }

    @Test("Quit tab")
    func quitSettings() async throws {
      let granted = QuitGuardSystemStatus(isAccessibilityTrusted: true, isSecureInputEnabled: false)
      let notGranted = QuitGuardSystemStatus(isAccessibilityTrusted: false, isSecureInputEnabled: false)
      let secureInput = QuitGuardSystemStatus(
        isAccessibilityTrusted: true,
        isSecureInputEnabled: true,
        secureInputAppName: "Terminal"
      )
      let secureInputUnknownApp = QuitGuardSystemStatus(isAccessibilityTrusted: true, isSecureInputEnabled: true)

      for locale in ["en", "ru"] {
        Defaults[.quitGuardApps] = ["com.apple.Terminal", "com.apple.Safari", "com.example.NotInstalled"]
        try await render(name: "settings-quit-granted-\(locale)", locale: locale) { QuitSettingsTab(status: granted) }
        try await render(name: "settings-quit-not-granted-\(locale)", locale: locale) {
          QuitSettingsTab(status: notGranted)
        }
        try await render(name: "settings-quit-secure-input-\(locale)", locale: locale) {
          QuitSettingsTab(status: secureInput)
        }
        try await render(name: "settings-quit-secure-input-unknown-app-\(locale)", locale: locale) {
          QuitSettingsTab(status: secureInputUnknownApp)
        }

        Defaults[.quitGuardApps] = []
        try await render(name: "settings-quit-empty-\(locale)", locale: locale) { QuitSettingsTab(status: granted) }
      }
    }

    // Rendered with the pre-macOS 26 material: offscreen rendering can't draw Liquid Glass.
    @Test("⌘Q guard HUD")
    func quitGuardHUD() async throws {
      for locale in ["en", "ru"] {
        try await render(name: "hud-\(locale)", locale: locale) {
          QuitGuardHUDView(appName: "Terminal", progress: 0.62, prefersGlass: false)
        }
        try await render(name: "hud-long-name-\(locale)", locale: locale) {
          QuitGuardHUDView(
            appName: "Microsoft Remote Desktop Connection Client for Enterprise Teams",
            progress: 0.25,
            prefersGlass: false
          )
        }
      }
    }

    // Multipasta: list copy.
    @Test("Popup with a list")
    func popupWithList() async throws {
      History.shared.add(Self.historyItem("https://github.com/eddytwist/multipasta"))
      let list = Self.historyItem("buy milk\ncall the bank\npick up the parcel\nbook a table")
      list.contents.append(
        HistoryItemContent(type: NSPasteboard.PasteboardType.multipastaList.rawValue, value: Data("4".utf8))
      )
      History.shared.add(list)
      let shortList = Self.historyItem("Отчёт за ноябрь\nСчёт №42")
      shortList.contents.append(
        HistoryItemContent(type: NSPasteboard.PasteboardType.multipastaList.rawValue, value: Data("2".utf8))
      )
      History.shared.add(shortList)
      // Two-digit count: its lines start where the others' do.
      let longList = Self.historyItem((1...12).map { "item \($0)" }.joined(separator: "\n"))
      longList.contents.append(
        HistoryItemContent(type: NSPasteboard.PasteboardType.multipastaList.rawValue, value: Data("12".utf8))
      )
      History.shared.add(longList)
      History.shared.add(Self.historyItem("npm run build && npm test"))

      for locale in ["en", "ru"] {
        try await renderPopup(name: "popup-list-\(locale)", height: 420, locale: locale) {
          AppState.shared.navigator.select(item: History.shared.unpinnedItems.first { $0.item.listEntryCount == 4 })
        }
      }
    }

    @Test("List copy HUD")
    func listCopyHUD() async throws {
      let messages: [(String, ListCopyHUDMessage)] = [
        ("added", .added(count: 3)),
        ("new", .newList),
        ("nothing", .nothingToAdd),
        ("only-text", .onlyText),
        ("hidden", .hiddenContent),
        ("paused", .paused),
        ("ignored", .ignored)
      ]
      for locale in ["en", "ru"] {
        for (name, message) in messages {
          try await render(name: "hud-list-\(name)-\(locale)", locale: locale) {
            ListCopyHUDView(message: message, prefersGlass: false)
          }
        }
      }
    }

    @Test("General tab: Add to list turned off for a duplicate shortcut")
    func addToListTurnedOff() async throws {
      for locale in ["en", "ru"] {
        Defaults[.addToListTurnedOffAsDuplicate] = true
        try await render(name: "settings-general-add-to-list-off-\(locale)", locale: locale) { GeneralSettingsTab() }
      }
      Defaults[.addToListTurnedOffAsDuplicate] = false
    }

    @Test("Advanced sheet: Lists section")
    func listCopySettings() async throws {
      let savedFormat = Defaults[.listFormat]
      let savedTimeout = Defaults[.listTimeout]
      defer {
        Defaults[.listFormat] = savedFormat
        Defaults[.listTimeout] = savedTimeout
      }
      for locale in ["en", "ru"] {
        Defaults[.listFormat] = .plain
        Defaults[.listTimeout] = .fifteenMinutes
        try await render(name: "settings-lists-\(locale)", locale: locale) {
          Form {
            ListCopySettingsSection()
          }
          .formStyle(.grouped)
          .scrollDisabled(true)
          .frame(width: SettingsLayout.width)
          .fixedSize(horizontal: false, vertical: true)
        }
        Defaults[.listFormat] = .numbered
        Defaults[.listTimeout] = .never
        try await render(name: "settings-lists-numbered-never-\(locale)", locale: locale) {
          Form {
            ListCopySettingsSection()
          }
          .formStyle(.grouped)
          .scrollDisabled(true)
          .frame(width: SettingsLayout.width)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }

    // MARK: - Rendering

    private func renderPopup(
      name: String,
      height: CGFloat,
      locale: String = "en",
      prepare: @MainActor () -> Void = {}
    ) async throws {
      try await History.shared.load()
      // ContentView reloads the history when it appears, so prepare the state afterwards.
      try await render(name: name, locale: locale, size: NSSize(width: 450, height: height), afterAppear: prepare) {
        ContentView()
      }
    }

    // Renders `content` in an offscreen window for each appearance. When `scrollPages` > 1,
    // the first scroll view inside is scrolled page by page and each page is saved separately.
    private func render<Content: View>(
      name: String,
      locale: String = "en",
      size: NSSize? = nil,
      scrollPages: Int = 1,
      afterAppear: @MainActor () -> Void = {},
      @ViewBuilder content: () -> Content
    ) async throws {
      try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      for (appearanceName, appearance) in appearances {
        let hostingView = NSHostingView(
          rootView: content()
            .environment(\.locale, Locale(identifier: locale))
            .background(Color(nsColor: .windowBackgroundColor))
        )
        let fittingSize = size ?? hostingView.fittingSize
        let window = NSWindow(
          contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: fittingSize),
          styleMask: [.borderless],
          backing: .buffered,
          defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        hostingView.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        window.orderFrontRegardless()
        window.alphaValue = 0.01

        try await Task.sleep(for: .milliseconds(1_000))
        afterAppear()
        // Let the search throttler and the list settle.
        try await Task.sleep(for: .milliseconds(1_000))

        let scrollView = Self.firstScrollView(in: hostingView)
        for page in 0..<max(scrollPages, 1) {
          if page > 0, let scrollView {
            let clip = scrollView.contentView
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let nextY = min(maxY, CGFloat(page) * clip.bounds.height * 0.9)
            clip.scroll(to: NSPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(250))
          }
          let suffix = scrollPages > 1 ? "-\(page + 1)" : ""
          try save(hostingView, appearance: appearance, to: "\(name)-\(appearanceName)\(suffix).png")
        }

        window.orderOut(nil)
        window.contentView = nil
      }
    }

    private func save(_ view: NSView, appearance: NSAppearance.Name, to fileName: String) throws {
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)

      // Composite onto an opaque window background so transparent areas read correctly.
      let image = NSImage(size: view.bounds.size)
      image.lockFocus()
      // Resolve the dynamic colour for the requested appearance before drawing with it.
      var background = NSColor.windowBackgroundColor.cgColor
      NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
        background = NSColor.windowBackgroundColor.cgColor
      }
      (NSColor(cgColor: background) ?? .windowBackgroundColor).setFill()
      NSRect(origin: .zero, size: view.bounds.size).fill()
      rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
      image.unlockFocus()

      let data = try #require(
        image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
      )
      try data.write(to: outputDirectory.appending(path: fileName))
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
      if let scrollView = view as? NSScrollView, (scrollView.documentView?.frame.height ?? 0) > 0 {
        return scrollView
      }
      for subview in view.subviews {
        if let found = firstScrollView(in: subview) {
          return found
        }
      }
      return nil
    }

    private static func historyItem(_ value: String) -> HistoryItem {
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        )
      ]
      item.numberOfCopies = 1
      item.title = item.generateTitle()
      return item
    }
  }
}
