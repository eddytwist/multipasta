import AppKit
import Testing
@testable import Maccy

// A Dock icon and ⌘Tab while a real window is open (Maccy/WindowPolicy.swift).
@MainActor
@Suite("Window policy")
struct WindowPolicyTests {
  typealias Window = WindowPolicy.Window

  static let settings = Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: false, isNormalLevel: true)
  static let closedSettings = Window(isVisible: false, isMiniaturized: false, isTitled: true, isPanel: false, isNormalLevel: true)
  static let minimizedSettings = Window(isVisible: false, isMiniaturized: true, isTitled: true, isPanel: false, isNormalLevel: true)
  // The popup is an untitled non-activating panel at the status bar level.
  static let popup = Window(isVisible: true, isMiniaturized: false, isTitled: false, isPanel: true, isNormalLevel: false)
  // The ⌘Q and list HUDs are untitled panels above normal windows.
  static let hud = Window(isVisible: true, isMiniaturized: false, isTitled: false, isPanel: true, isNormalLevel: false)
  // NSAlert and the About window are titled panels.
  static let alert = Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: true, isNormalLevel: false)
  static let about = Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: true, isNormalLevel: true)
  // The status item lives in an untitled window; menus float above normal windows.
  static let statusItem = Window(isVisible: true, isMiniaturized: false, isTitled: false, isPanel: false, isNormalLevel: false)
  static let menu = Window(isVisible: true, isMiniaturized: false, isTitled: false, isPanel: false, isNormalLevel: false)
  static let floatingTitled = Window(isVisible: true, isMiniaturized: false, isTitled: true, isPanel: false, isNormalLevel: false)

  @Test("A shown or minimized titled normal window is real")
  func realWindows() {
    #expect(Self.settings.isReal)
    #expect(Self.minimizedSettings.isReal)
    #expect(!Self.closedSettings.isReal)
  }

  @Test("The popup, HUDs, alerts, the About window, menus and the status item are not real windows")
  func notRealWindows() {
    for window in [Self.popup, Self.hud, Self.alert, Self.about, Self.statusItem, Self.menu, Self.floatingTitled] {
      #expect(!window.isReal)
    }
  }

  @Test("Regular while a real window is open, accessory otherwise")
  func wantedPolicy() {
    #expect(WindowPolicy.wantedPolicy(for: []) == .accessory)
    #expect(WindowPolicy.wantedPolicy(for: [Self.statusItem, Self.closedSettings]) == .accessory)
    #expect(WindowPolicy.wantedPolicy(for: [Self.statusItem, Self.popup]) == .accessory)
    #expect(WindowPolicy.wantedPolicy(for: [Self.statusItem, Self.hud, Self.alert, Self.about]) == .accessory)
    #expect(WindowPolicy.wantedPolicy(for: [Self.statusItem, Self.settings]) == .regular)
    #expect(WindowPolicy.wantedPolicy(for: [Self.statusItem, Self.popup, Self.settings]) == .regular)
    #expect(WindowPolicy.wantedPolicy(for: [Self.statusItem, Self.minimizedSettings]) == .regular)
  }

  @Test("Nothing happens while the policy is already right, the popup alone included")
  func noChange() {
    #expect(WindowPolicy.change(from: .accessory, to: .accessory, isActive: false, isPopupShown: true) == nil)
    #expect(WindowPolicy.change(from: .accessory, to: .accessory, isActive: true, isPopupShown: true) == nil)
    #expect(WindowPolicy.change(from: .regular, to: .regular, isActive: true, isPopupShown: false) == nil)
  }

  @Test("Opening a window makes the app regular and brings it forward")
  func becomeRegular() {
    #expect(WindowPolicy.change(from: .accessory, to: .regular, isActive: false, isPopupShown: false) == .becomeRegular)
    #expect(WindowPolicy.change(from: .accessory, to: .regular, isActive: true, isPopupShown: true) == .becomeRegular)
  }

  @Test("Closing the last window hides the active app, but never the shown popup")
  func becomeAccessory() {
    #expect(WindowPolicy.change(from: .regular, to: .accessory, isActive: true, isPopupShown: false) == .becomeAccessory(hide: true))
    #expect(WindowPolicy.change(from: .regular, to: .accessory, isActive: false, isPopupShown: false) == .becomeAccessory(hide: false))
    #expect(WindowPolicy.change(from: .regular, to: .accessory, isActive: true, isPopupShown: true) == .becomeAccessory(hide: false))
  }

  @Test("A real AppKit window and panel are classified from their properties")
  func appKitWindows() {
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    #expect(Window(window) == Self.closedSettings)
    let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = .statusBar
    #expect(Window(panel) == Window(isVisible: false, isMiniaturized: false, isTitled: false, isPanel: true, isNormalLevel: false))
  }

  /// SwiftUI builds the main menu once the app has launched.
  private func mainMenu() async throws -> NSMenu {
    for _ in 0..<40 {
      if let menu = NSApp.mainMenu, menu.items.count > 1 { return menu }
      try await Task.sleep(for: .milliseconds(50))
    }
    return try #require(NSApp.mainMenu)
  }

  private func item(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
    menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == action }
  }

  @Test("In the regular app's menu bar ⌘A, ⌘C, ⌘V, ⌘X and ⌘Q keep working")
  func editAndQuitItems() async throws {
    let menu = try await mainMenu()
    for (action, key) in [
      (#selector(NSText.selectAll(_:)), "a"),
      (#selector(NSText.copy(_:)), "c"),
      (#selector(NSText.paste(_:)), "v"),
      (#selector(NSText.cut(_:)), "x"),
      (#selector(NSApplication.terminate(_:)), "q")
    ] {
      let item = try #require(item(action, in: menu), "\(action)")
      #expect(item.keyEquivalent == key)
      #expect(item.keyEquivalentModifierMask == .command)
    }
  }

  @Test("File → Close is ⌘W, added once, and off while no real window is key")
  func closeItem() async throws {
    let menu = try await mainMenu()
    WindowPolicy.installCloseItem()
    WindowPolicy.installCloseItem()
    let close = try #require(WindowPolicy.closeItem(in: menu))
    #expect(close.keyEquivalent == "w")
    #expect(close.keyEquivalentModifierMask == .command)
    let count = menu.items.flatMap { $0.submenu?.items ?? [] }.filter { $0.action == close.action }.count
    #expect(count == 1)
    if NSApp.keyWindow.map({ !Window($0).isReal }) ?? true {
      #expect(WindowPolicy.CloseTarget.shared.validateMenuItem(close) == false)
    }
  }
}
