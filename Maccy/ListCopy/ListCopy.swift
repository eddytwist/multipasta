// swiftlint:disable file_length
import AppKit
import Defaults
import KeyboardShortcuts
import os
import Sauce

// Multipasta: list copy.
//
// The add-to-list shortcut (⇧⌘C by default) presses ⌘C in the front app, takes the copied
// text and appends it to the current list. The whole list goes on the clipboard and into
// the history as one item, which is updated in place on each addition.
//
// A new list starts when there is no list yet, when the current one was pasted or chosen in
// the popup, when its history item is pinned, and when the last addition is older than the
// timeout in Settings → Advanced. "Pasted" means some app asked the clipboard for the list's
// text: the text is put on the clipboard lazily (ListPasteboardProvider) and that request is
// the signal.
//
// What the history wouldn't save isn't added either: concealed and transient copies
// (password managers), copies while history is paused, from ignored apps, of ignored types or
// matching an ignored regular expression. Then the clipboard gets back what it had before.
@MainActor
final class ListCopy { // swiftlint:disable:this type_body_length
  /// Everything list copy needs from the outside, so that tests can run it on a private
  /// pasteboard with a fake key press.
  struct Environment {
    var pasteboard: NSPasteboard
    var isTrusted: @MainActor () -> Bool
    /// Presses ⌘C in the front app.
    var postCopy: @MainActor () -> Void
    var waitForModifierRelease: @MainActor () async -> Void
    var now: @MainActor () -> Date
    var frontmostApp: @MainActor () -> String?
    /// Multipasta's popup or settings window has the keyboard.
    var hasOwnKeyWindow: @MainActor () -> Bool
    var showHUD: @MainActor (ListCopyHUDMessage) -> Void
    var showAccessibilityAlert: @MainActor () -> Void
    /// Tells the clipboard watcher that it has seen the clipboard up to this change count.
    var markPasteboardSeen: @MainActor (Int) -> Void
    /// How long to wait for the front app to copy (Word, JetBrains IDEs and virtual machines
    /// can be slow). After that "Nothing to add" shows and nothing more goes into the list.
    var copyTimeout: TimeInterval = 1.5
    /// The most the previous clipboard may weigh to be kept for putting back.
    var snapshotLimit = PasteboardSnapshot.defaultLimit

    static func live(hud: ListCopyHUD) -> Environment {
      Environment(
        pasteboard: .general,
        isTrusted: { Accessibility.isTrusted },
        postCopy: { ListCopyKeyboard.postCopy() },
        waitForModifierRelease: { await ListCopyKeyboard.waitForModifierRelease() },
        now: { Date() },
        frontmostApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        hasOwnKeyWindow: { NSApp.isActive || NSApp.keyWindow?.isVisible == true },
        showHUD: { hud.show($0) },
        showAccessibilityAlert: { ListCopy.showAccessibilityAlert() },
        markPasteboardSeen: { Clipboard.shared.changeCount = $0 }
      )
    }
  }

  enum Phase: Equatable {
    case idle
    /// ⌘C was pressed; waiting for the front app to copy.
    case capturing
  }

  static let shared = ListCopy(environment: .live(hud: ListCopyHUD()))
  static let logger = os.Logger(subsystem: "com.eddytwist.Multipasta", category: "list")
  static let pollInterval: Duration = .milliseconds(20)

  private static let instances = NSHashTable<ListCopy>.weakObjects()

  private(set) var session = ListSession()
  /// The history item that shows the current list.
  private(set) var historyItem: HistoryItem?
  private(set) var phase = Phase.idle

  private var environment: Environment
  private var pasteboard: NSPasteboard { environment.pasteboard }
  private var isStarted = false
  private var isShowingAccessibilityAlert = false
  /// Bumped for each capture and by `reset(clearingPasteboard:)`; a capture or a queued press whose number is no
  /// longer current is dropped.
  private var captureGeneration = 0
  /// A press that came while ⌘C was being waited for, with the capture it waited behind;
  /// handled right after that capture unless something superseded it.
  private var pendingPressGeneration: Int?

  /// The provider of the list on the clipboard, and the clipboard's change count right after
  /// it was written. Nil once something else is on the clipboard.
  private var pendingProvider: ListPasteboardProvider?
  private var pendingCount = 0
  private var listChangeCount: Int?
  private var nextToken: UInt64 = 0

  init(environment: Environment) {
    self.environment = environment
    Self.instances.add(self)
  }

  /// Unit tests run inside the app; keep the global shortcut out of them.
  private static var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  func start() {
    guard !isStarted, !Self.isRunningUnitTests else {
      return
    }
    isStarted = true

    // One combination can't do both; Settings refuses it, but older settings may have it
    // (Maccy's popup default is ⇧⌘C).
    if Self.isDuplicate(KeyboardShortcuts.getShortcut(for: .addToList), of: KeyboardShortcuts.getShortcut(for: .popup)) {
      Self.logger.error("Add to list had the same shortcut as Open history; it is turned off until set again")
      KeyboardShortcuts.setShortcut(nil, for: .addToList)
      // Settings → General says so once, under the recorder.
      Defaults[.addToListTurnedOffAsDuplicate] = true
    }

    KeyboardShortcuts.onKeyDown(for: .addToList) {
      MainActor.assumeIsolated {
        ListCopy.shared.addSelection()
      }
    }
  }

  /// True when `shortcut` is set and equals `other`.
  nonisolated static func isDuplicate(_ shortcut: KeyboardShortcuts.Shortcut?, of other: KeyboardShortcuts.Shortcut?) -> Bool {
    guard let shortcut else {
      return false
    }
    return shortcut == other
  }

  // MARK: - Hooks for Clipboard, History and AppDelegate

  /// True for clipboard changes that are list copy's business: while it waits for the copy it
  /// asked for, and the list it wrote. The clipboard watcher must neither record them nor read
  /// the list's text, which would count as a paste. The watcher leaves its change count alone
  /// for these, so a change list copy hands back is still recorded afterwards.
  func shouldIgnorePasteboardChange(_ changeCount: Int) -> Bool {
    phase != .idle || changeCount == listChangeCount
  }

  /// Multipasta is about to put `item` on the clipboard (chosen in the popup). When it's the
  /// current list, the list is done.
  static func willCopy(_ item: HistoryItem) {
    for instance in instances.allObjects {
      instance.willCopy(item)
    }
  }

  private func willCopy(_ item: HistoryItem) {
    pendingProvider = nil
    listChangeCount = nil
    if let historyItem, historyItem == item {
      session.markPasted()
    }
  }

  /// The history lost `item`, or everything when `item` is nil (Clear, Clear all). When the
  /// current list went with it, the list ends and won't come back into the history.
  static func historyDidRemove(_ item: HistoryItem?) {
    for instance in instances.allObjects {
      instance.historyDidRemove(item)
    }
  }

  private func historyDidRemove(_ item: HistoryItem?) {
    if let item {
      // Deleting the list's item (⌥⌫) ends the list; like Maccy, the clipboard stays as it is.
      guard let historyItem, historyItem == item else {
        return
      }
      reset(clearingPasteboard: false)
    } else {
      // Clear and Clear all take the list off the clipboard only with "Clear system clipboard".
      reset(clearingPasteboard: Defaults[.clearSystemClipboard])
    }
  }

  /// Ends the list and drops a capture in progress and a queued press. With
  /// `clearingPasteboard`, the list is also taken off the clipboard if it's still there.
  /// Otherwise it stays there as it is, and is still handed over on quit.
  func reset(clearingPasteboard: Bool) {
    captureGeneration += 1
    pendingPressGeneration = nil
    session.reset()
    historyItem = nil
    guard clearingPasteboard else {
      return
    }
    if let listChangeCount, listChangeCount == pasteboard.changeCount {
      pasteboard.clearContents()
      environment.markPasteboardSeen(pasteboard.changeCount)
    }
    pendingProvider = nil
    pendingCount = 0
    listChangeCount = nil
  }

  /// Hands the list's text to the clipboard before quitting, so the clipboard isn't left empty
  /// once nobody can provide it.
  func applicationWillTerminate() {
    guard let provider = pendingProvider,
          listChangeCount == pasteboard.changeCount,
          !provider.hasProvided else {
      return
    }
    _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
    pasteboard.setString(provider.text, forType: .string)
    pasteboard.setString(String(pendingCount), forType: .multipastaList)
    pendingProvider = nil
    listChangeCount = nil
  }

  // MARK: - Adding

  func addSelection() {
    Task {
      await add()
    }
  }

  /// Handles one press of the shortcut, including a press queued meanwhile.
  func add() async {
    if phase == .capturing {
      // Pressed again before the front app copied: do it once more right after.
      pendingPressGeneration = captureGeneration
      return
    }

    guard !isShowingAccessibilityAlert else {
      return
    }
    guard environment.isTrusted() else {
      Self.logger.error("Add to list skipped: Accessibility is not granted to this build")
      isShowingAccessibilityAlert = true
      environment.showAccessibilityAlert()
      isShowingAccessibilityAlert = false
      return
    }
    // The popup or the settings window has the keyboard: there's no other app to copy from.
    if environment.hasOwnKeyWindow() {
      environment.showHUD(.nothingToAdd)
      return
    }

    await capture()

    if let pending = pendingPressGeneration {
      pendingPressGeneration = nil
      // Not when the list was reset meanwhile: that press belonged to what was dropped.
      if pending == captureGeneration, phase == .idle {
        await add()
      }
    }
  }

  private func capture() async {
    phase = .capturing
    captureGeneration += 1
    let generation = captureGeneration
    let sourceApp = environment.frontmostApp()

    await environment.waitForModifierRelease()
    let before = pasteboard.changeCount
    let listWasOnPasteboard = listChangeCount == before
    // What to put back if the copy can't go into the list. The list itself is never read
    // here: reading it would count as pasting it.
    let previous = listWasOnPasteboard ? nil : PasteboardSnapshot(pasteboard, limit: environment.snapshotLimit)
    let context = CaptureContext(
      before: before,
      listWasOnPasteboard: listWasOnPasteboard,
      previous: previous,
      sourceApp: sourceApp
    )

    environment.postCopy()
    let copied = await waitForCopy(after: before, timeout: environment.copyTimeout, generation: generation)
    defer { phase = .idle }
    // Reset meanwhile (history cleared): the copy is no longer wanted.
    guard generation == captureGeneration else {
      return
    }
    if copied {
      finishCapture(context)
    } else {
      // Only now, so that a ⌘C the user makes after reading it is an ordinary copy.
      environment.showHUD(.nothingToAdd)
    }
  }

  /// Polls the clipboard without blocking the main thread. True when the front app wrote to it.
  private func waitForCopy(after before: Int, timeout: TimeInterval, generation: Int) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try? await Task.sleep(for: Self.pollInterval)
      guard generation == captureGeneration else {
        return false
      }
      if pasteboard.changeCount != before, !(pasteboard.types ?? []).isEmpty {
        // Some apps clear the clipboard and write to it in separate steps: give them a beat.
        try? await Task.sleep(for: Self.pollInterval)
        return generation == captureGeneration
      }
    }
    return generation == captureGeneration && pasteboard.changeCount != before
  }

  private struct CaptureContext {
    let before: Int
    let listWasOnPasteboard: Bool
    let previous: PasteboardSnapshot?
    let sourceApp: String?
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func finishCapture(_ context: CaptureContext) {
    let types = Set(pasteboard.types ?? [])
    let clipboard = Clipboard.shared

    guard !types.isEmpty else {
      refuse(.nothingToAdd, context)
      return
    }

    // Password managers mark secrets this way: never into a list, whatever the settings.
    if !types.isDisjoint(with: clipboard.ignoredTypes) {
      refuse(.hiddenContent, context)
      return
    }

    if Defaults[.ignoreEvents] {
      // Same as the clipboard watcher: "ignore only the next copy" is used up by this one.
      if Defaults[.ignoreOnlyNextEvent] {
        Defaults[.ignoreEvents] = false
        Defaults[.ignoreOnlyNextEvent] = false
      }
      refuse(.paused, context)
      return
    }

    guard let string = Self.plainText(on: pasteboard, types: types) else {
      if context.listWasOnPasteboard {
        refuse(.onlyText, context)
      } else {
        // A real copy of an image or files: the clipboard watcher records it as usual.
        environment.showHUD(.onlyText)
      }
      return
    }

    let ignoredByRule = clipboard.shouldIgnore(types)
      || context.sourceApp.map(clipboard.shouldIgnore) == true
      || (pasteboard.pasteboardItems ?? []).contains(where: clipboard.shouldIgnore)
    if ignoredByRule {
      refuse(.ignored, context)
      return
    }

    // A pinned list stays as it is; the next one is new.
    if let historyItem, historyItem.pin != nil {
      session.reset()
      self.historyItem = nil
    }

    let now = environment.now()
    switch session.add(string, at: now, timeout: Defaults[.listTimeout].interval) {
    case .ignored:
      refuse(.nothingToAdd, context)
    case .added(let count, let startedNewList):
      if startedNewList {
        historyItem = nil
      }
      let text = session.text(format: Defaults[.listFormat])
      updateHistory(text: text, count: count, date: now, sourceApp: context.sourceApp)
      writeList(text: text, count: count)
      environment.markPasteboardSeen(pasteboard.changeCount)
      environment.showHUD(startedNewList ? .newList : .added(count: count))
      Self.logger.info("Added to list: \(count) entries")
    }
  }

  /// Doesn't add the copy, and the history doesn't record it. The clipboard gets back the list
  /// or, when it was small enough to keep, another app's earlier copy. A kept copy that was
  /// concealed or transient (a password) is not put back: rewritten, it would stay on the
  /// clipboard without its password manager's auto-clear. Then, and when nothing could be
  /// kept, the clipboard stays as the front app's ⌘C left it, auto-clear included.
  private func refuse(_ message: ListCopyHUDMessage, _ context: CaptureContext) {
    if context.listWasOnPasteboard, let provider = pendingProvider {
      writeList(text: provider.text, count: pendingCount)
    } else if let previous = context.previous, !previous.isConcealed {
      previous.write(to: pasteboard)
    }
    environment.markPasteboardSeen(pasteboard.changeCount)
    environment.showHUD(message)
  }

  /// The copied plain text, or nil for files (Finder adds their names as text), images and
  /// other content without text. Rich text editors put an object replacement character in the
  /// text for each image; those are dropped, and an image alone counts as no text.
  private static func plainText(on pasteboard: NSPasteboard, types: Set<NSPasteboard.PasteboardType>) -> String? {
    guard !types.contains(.fileURL), let string = pasteboard.string(forType: .string) else {
      return nil
    }
    let text = string.replacingOccurrences(of: "\u{FFFC}", with: "")
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !string.isEmpty && text != string
      ? nil
      : text
  }

  // MARK: - Clipboard

  private func writeList(text: String, count: Int) {
    nextToken += 1
    let provider = ListPasteboardProvider(text: text, token: nextToken) { token in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          for instance in ListCopy.instances.allObjects {
            instance.listWasRequested(token: token)
          }
        }
      }
    }
    // This Mac only: Universal Clipboard could otherwise fetch the text for nearby devices
    // right away, which would look like a paste and end the list at once.
    _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
    pasteboard.writeObjects([ListPasteboardProvider.item(provider: provider, count: count)])
    pendingProvider = provider
    pendingCount = count
    listChangeCount = pasteboard.changeCount
  }

  private func listWasRequested(token: UInt64) {
    guard let pendingProvider, token == pendingProvider.token else {
      return
    }
    Self.logger.info("List pasted: the next addition starts a new list")
    session.markPasted()
  }

  // MARK: - History

  private func updateHistory(text: String, count: Int, date: Date, sourceApp: String?) {
    if let historyItem {
      let updated = History.shared.updateInPlace(historyItem) { item in
        item.contents.forEach(Storage.shared.context.delete)
        item.contents = Self.contents(text: text, count: count)
        item.lastCopiedAt = date
        item.title = item.generateTitle()
      }
      if updated {
        return
      }
      // Merged into another item meanwhile (deleting it resets the list): add it again.
    }

    let item = HistoryItem(contents: Self.contents(text: text, count: count))
    if #unavailable(macOS 15.0) {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      try? History.shared.insertIntoStorage(item)
    }
    item.application = sourceApp
    item.firstCopiedAt = date
    item.lastCopiedAt = date
    item.title = item.generateTitle()
    // The HUD already tells: no notification or sound.
    historyItem = History.shared.add(item, notify: false).item
  }

  private static func contents(text: String, count: Int) -> [HistoryItemContent] {
    [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8)),
      HistoryItemContent(type: NSPasteboard.PasteboardType.multipastaList.rawValue, value: Data(String(count).utf8))
    ]
  }

  // MARK: - Accessibility

  private static func showAccessibilityAlert() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = NSLocalizedString("ListAccessibilityTitle", tableName: "MultipastaSettings", comment: "")
    alert.informativeText = NSLocalizedString("ListAccessibilityMessage", tableName: "MultipastaSettings", comment: "")
    alert.addButton(withTitle: NSLocalizedString("QuitOpenSystemSettings", tableName: "MultipastaSettings", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("ListAccessibilityCancel", tableName: "MultipastaSettings", comment: ""))
    if alert.runModal() == .alertFirstButtonReturn {
      Accessibility.openSystemSettings()
    }
  }
}

/// What was on the clipboard before list copy pressed ⌘C, to put back when the copy can't go
/// into the list. Only the types the history keeps are read (text, rich text, HTML, images,
/// file URLs), in that order, and only up to `limit` bytes in all; other types, including
/// other apps' lazily provided ones, are never asked for.
struct PasteboardSnapshot {
  static let defaultLimit = 8 * 1024 * 1024
  /// Text first, so that a snapshot that runs over the limit fails before reading images.
  static let keptTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .fileURL, .png, .jpeg, .heic, .tiff]
  static let concealedTypes: Set<NSPasteboard.PasteboardType> = [.concealed, .transient]

  private let items: [[(NSPasteboard.PasteboardType, Data)]]
  /// The copy was marked concealed or transient (password managers).
  let isConcealed: Bool

  /// Nil when the kept types weigh more than `limit`.
  init?(_ pasteboard: NSPasteboard, limit: Int = defaultLimit) {
    let pasteboardItems = pasteboard.pasteboardItems ?? []
    isConcealed = pasteboardItems.contains { !Set($0.types).isDisjoint(with: Self.concealedTypes) }

    var total = 0
    var items: [[(NSPasteboard.PasteboardType, Data)]] = []
    for item in pasteboardItems {
      let available = Set(item.types)
      var pairs: [(NSPasteboard.PasteboardType, Data)] = []
      for type in Self.keptTypes where available.contains(type) {
        guard let data = item.data(forType: type) else {
          continue
        }
        total += data.count
        if total > limit {
          return nil
        }
        pairs.append((type, data))
      }
      items.append(pairs)
    }
    self.items = items
  }

  var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

  func write(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let pasteboardItems = items.filter { !$0.isEmpty }.map { pairs in
      let item = NSPasteboardItem()
      for (type, data) in pairs {
        item.setData(data, forType: type)
      }
      return item
    }
    if !pasteboardItems.isEmpty {
      pasteboard.writeObjects(pasteboardItems)
    }
  }
}

enum ListCopyKeyboard {
  /// The key that gives ⌘C in the current layout, found the same way as ⌘V in
  /// Clipboard.paste(): layouts that switch to QWERTY with ⌘ use the QWERTY key, and Sauce
  /// falls back to it for layouts without a Latin C.
  static var copyKeyCode: CGKeyCode {
    if KeyboardLayout.current.commandSwitchesToQWERTY {
      return Key.c.QWERTYKeyCode
    }
    return Sauce.shared.keyCode(for: .c)
  }

  /// Presses ⌘C in the front app, with the same event source settings as Clipboard.paste().
  static func postCopy() {
    // The left ⌘ flag next to ⌘, see https://github.com/TermiT/Flycut/pull/18.
    let commandFlag = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
    let keyCode = copyKeyCode

    let source = CGEventSource(stateID: .combinedSessionState)
    // Ignore the user's keyboard while the keys are posted.
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyDown?.flags = commandFlag
    keyUp?.flags = commandFlag
    keyDown?.post(tap: .cgSessionEventTap)
    keyUp?.post(tap: .cgSessionEventTap)
  }

  /// Waits up to 0.3 s for the shortcut's extra modifiers (⇧, ⌥, ⌃) to be released, so the
  /// front app doesn't see them held with the ⌘C.
  static func waitForModifierRelease() async {
    let deadline = Date().addingTimeInterval(0.3)
    while Date() < deadline {
      let flags = CGEventSource.flagsState(.combinedSessionState)
      if flags.isDisjoint(with: [.maskShift, .maskAlternate, .maskControl]) {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}
