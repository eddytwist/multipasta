import AppKit
import Defaults
import KeyboardShortcuts
import Testing
@testable import Maccy

extension SharedStateTests {
  // ListCopy end to end on a private pasteboard: the "front app" is a closure that writes to
  // it when list copy presses ⌘C. The history is the real one, cleared before each test.
  @MainActor
  final class ListCopyTests { // swiftlint:disable:this type_body_length
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    let savedFormat = Defaults[.listFormat]
    let savedTimeout = Defaults[.listTimeout]
    let savedIgnoredApps = Defaults[.ignoredApps]
    let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
    let savedIgnoreEvents = Defaults[.ignoreEvents]
    let savedIgnoreOnlyNextEvent = Defaults[.ignoreOnlyNextEvent]
    let savedIgnoreRegexp = Defaults[.ignoreRegexp]
    let savedSortBy = Defaults[.sortBy]
    let savedClearSystemClipboard = Defaults[.clearSystemClipboard]

    let pasteboardName = NSPasteboard.Name("com.eddytwist.Multipasta.tests.\(UUID().uuidString)")
    lazy var pasteboard = NSPasteboard(name: pasteboardName)
    var huds: [ListCopyHUDMessage] = []
    var seenChangeCounts: [Int] = []
    var alerts = 0
    var listSounds = 0
    var trusted = true
    var frontmostApp: String? = "com.apple.TextEdit"
    /// What the front app does on ⌘C.
    var onCopy: (NSPasteboard) -> Void = { _ in }

    lazy var listCopy = ListCopy(environment: ListCopy.Environment(
      pasteboard: pasteboard,
      isTrusted: { [unowned self] in trusted },
      postCopy: { [unowned self] in onCopy(pasteboard) },
      waitForModifierRelease: {},
      now: { Date() },
      frontmostApp: { [unowned self] in frontmostApp },
      hasOwnKeyWindow: { false },
      showHUD: { [unowned self] in huds.append($0) },
      showAccessibilityAlert: { [unowned self] in alerts += 1 },
      markPasteboardSeen: { [unowned self] in seenChangeCounts.append($0) },
      copyTimeout: 0.25,
      snapshotLimit: 1_000,
      playListSound: { [unowned self] in listSounds += 1 }
    ))

    init() {
      History.shared.clearAll()
      Defaults[.listFormat] = .plain
      Defaults[.listTimeout] = .fifteenMinutes
      Defaults[.ignoredApps] = []
      Defaults[.ignoreAllAppsExceptListed] = false
      Defaults[.ignoreEvents] = false
      Defaults[.ignoreOnlyNextEvent] = false
      Defaults[.ignoreRegexp] = []
      Defaults[.sortBy] = .lastCopiedAt
      // History.clear() would clear the real system clipboard with this on.
      Defaults[.clearSystemClipboard] = false
    }

    deinit {
      NSPasteboard(name: pasteboardName).releaseGlobally()
      Defaults[.listFormat] = savedFormat
      Defaults[.listTimeout] = savedTimeout
      Defaults[.ignoredApps] = savedIgnoredApps
      Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
      Defaults[.ignoreEvents] = savedIgnoreEvents
      Defaults[.ignoreOnlyNextEvent] = savedIgnoreOnlyNextEvent
      Defaults[.ignoreRegexp] = savedIgnoreRegexp
      Defaults[.sortBy] = savedSortBy
      Defaults[.clearSystemClipboard] = savedClearSystemClipboard
    }

    // MARK: - Adding

    @Test("Each press adds a line; the list is one history item and is on the clipboard")
    func addsLines() async {
      await press(copying: "milk")
      await press(copying: "bread\n")
      #expect(huds == [.newList, .added(count: 2)])
      #expect(listCopy.session.entries == ["milk", "bread"])

      let items = History.shared.items.toArray()
      #expect(items.count == 1)
      #expect(items.first?.item.text == "milk\nbread")
      #expect(items.first?.item.listEntryCount == 2)

      #expect(listIsOnPasteboard)
      #expect(seenChangeCounts.last == pasteboard.changeCount)
      // Reading it here is a paste, so only now.
      #expect(pasteboard.string(forType: .string) == "milk\nbread")
    }

    @Test("A request for the list's text (a paste) ends the list")
    func pasteEndsList() async throws {
      await press(copying: "milk")
      #expect(pasteboard.string(forType: .string) == "milk")
      try await Task.sleep(for: .milliseconds(50))
      #expect(listCopy.session.wasPasted)

      await press(copying: "bread")
      #expect(huds == [.newList, .newList])
      #expect(listCopy.session.entries == ["bread"])
      #expect(History.shared.items.toArray().compactMap(\.item.text).sorted() == ["bread", "milk"])
    }

    @Test("The format applies to the clipboard and the history")
    func format() async {
      Defaults[.listFormat] = .numbered
      await press(copying: "milk")
      await press(copying: "bread")
      #expect(History.shared.items.first?.item.text == "1. milk\n2. bread")
    }

    @Test("List copy's own changes are ignored by the watcher, others are not")
    func ownChangesIgnored() async {
      var ignoredWhileCapturing = false
      onCopy = { [unowned self] pasteboard in
        pasteboard.clearContents()
        pasteboard.setString("milk", forType: .string)
        ignoredWhileCapturing = listCopy.phase == .capturing
          && listCopy.shouldIgnorePasteboardChange(pasteboard.changeCount)
      }
      await listCopy.add()
      #expect(ignoredWhileCapturing)
      #expect(listCopy.shouldIgnorePasteboardChange(pasteboard.changeCount))

      pasteboard.clearContents()
      pasteboard.setString("someone else's copy", forType: .string)
      #expect(!listCopy.shouldIgnorePasteboardChange(pasteboard.changeCount))
    }

    @Test("A second press while waiting for the copy is handled right after")
    func queuedPress() async {
      var texts = ["milk", "bread"]
      onCopy = { [unowned self] pasteboard in
        if texts.count == 2 {
          // The user presses again before the first copy arrived.
          listCopy.addSelection()
        }
        pasteboard.clearContents()
        pasteboard.setString(texts.removeFirst(), forType: .string)
      }
      await listCopy.add()
      #expect(huds == [.newList, .added(count: 2)])
      #expect(listCopy.session.entries == ["milk", "bread"])
    }

    @Test("Every added line plays the list sound, the first and the later ones; Nothing to add doesn't")
    func listSound() async {
      await press(copying: "milk")
      await press(copying: "bread")
      await press(copying: "eggs")
      #expect(listSounds == 3)

      await press(copying: nil)
      #expect(huds.last == .nothingToAdd)
      #expect(listSounds == 3)
    }

    @Test("A refused copy plays no list sound")
    func refusedNoSound() async {
      Defaults[.ignoredApps] = ["com.apple.TextEdit"]
      await press(copying: "secret")
      #expect(huds == [.ignored])
      #expect(listSounds == 0)
    }

    // MARK: - Nothing or non-text

    @Test("No copy: Nothing to add, and the clipboard is left alone")
    func nothingCopied() async {
      setPrevious("previous")
      let before = pasteboard.changeCount
      await press(copying: nil)
      #expect(huds == [.nothingToAdd])
      #expect(pasteboard.changeCount == before)
      #expect(listCopy.phase == .idle)
      #expect(History.shared.items.count == 0)
    }

    @Test("Nothing to add shows only at the end of the wait; a ⌘C after it is an ordinary copy")
    func userCopyAfterHUD() async {
      var hudsDuringWait: [ListCopyHUDMessage]?
      onCopy = { [unowned self] _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          MainActor.assumeIsolated { hudsDuringWait = self.huds }
        }
      }
      await listCopy.add()
      #expect(hudsDuringWait == [])
      #expect(huds == [.nothingToAdd])
      #expect(listCopy.phase == .idle)

      // The user selects and presses ⌘C themselves.
      pasteboard.clearContents()
      pasteboard.setString("ordinary copy", forType: .string)
      #expect(!listCopy.shouldIgnorePasteboardChange(pasteboard.changeCount))
      try? await Task.sleep(for: .milliseconds(300))
      #expect(listCopy.session.isEmpty)
      #expect(History.shared.items.count == 0)
    }

    @Test("A press queued behind a capture that was reset is dropped")
    func stalePendingPressDropped() async throws {
      var copies = 0
      onCopy = { [unowned self] pasteboard in
        copies += 1
        // Pressed again while waiting…
        listCopy.addSelection()
        // …then the history is cleared before the copy arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          MainActor.assumeIsolated {
            self.listCopy.reset(clearingPasteboard: false)
            pasteboard.clearContents()
            pasteboard.setString("milk", forType: .string)
          }
        }
      }
      await listCopy.add()
      try await Task.sleep(for: .milliseconds(400))
      #expect(copies == 1)
      #expect(huds.isEmpty)
      #expect(listCopy.session.isEmpty)
      #expect(listCopy.phase == .idle)
    }

    @Test("An image with a list on the clipboard: the list is put back")
    func imageRestoresList() async {
      await press(copying: "milk")
      onCopy = Self.copyImage
      await listCopy.add()
      #expect(huds == [.newList, .onlyText])
      #expect(listIsOnPasteboard)
      #expect(listCopy.session.entries == ["milk"])
      #expect(History.shared.items.count == 1)
      #expect(seenChangeCounts.last == pasteboard.changeCount)
    }

    @Test("An image without a list: left on the clipboard for the watcher to record")
    func imageWithoutList() async {
      setPrevious("previous")
      onCopy = Self.copyImage
      await listCopy.add()
      #expect(huds == [.onlyText])
      #expect(pasteboard.types?.contains(.tiff) == true)
      #expect(!seenChangeCounts.contains(pasteboard.changeCount))
      #expect(!listCopy.shouldIgnorePasteboardChange(pasteboard.changeCount))
      #expect(listCopy.session.isEmpty)
    }

    @Test("Files are not text, even with their names as text")
    func filesAreNotText() async {
      onCopy = { pasteboard in
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("file:///tmp/a.txt", forType: .fileURL)
        item.setString("a.txt", forType: .string)
        pasteboard.writeObjects([item])
      }
      await listCopy.add()
      #expect(huds == [.onlyText])
      #expect(listCopy.session.isEmpty)
    }

    @Test("An image copied from a rich text editor is not text; images inside text are dropped")
    func imageAttachment() async {
      await press(copying: "\u{FFFC}")
      #expect(huds == [.onlyText])
      await press(copying: "see\u{FFFC} here")
      #expect(huds == [.onlyText, .newList])
      #expect(listCopy.session.entries == ["see here"])
    }

    // MARK: - What the history wouldn't save

    @Test("Concealed content is refused and the previous clipboard comes back")
    func concealedRefused() async {
      setPrevious("previous")
      onCopy = { pasteboard in
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: Self.concealed)
      }
      await listCopy.add()
      #expect(huds == [.hiddenContent])
      #expect(pasteboard.string(forType: .string) == "previous")
      #expect(pasteboard.types?.contains(Self.concealed) == false)
      #expect(listCopy.session.isEmpty)
      #expect(History.shared.items.count == 0)
      #expect(seenChangeCounts.last == pasteboard.changeCount)
    }

    @Test("Concealed content with a list on the clipboard: the list comes back")
    func concealedRestoresList() async {
      await press(copying: "milk")
      onCopy = { pasteboard in
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: .transient)
      }
      await listCopy.add()
      #expect(huds == [.newList, .hiddenContent])
      #expect(listIsOnPasteboard)
      #expect(History.shared.items.first?.item.text == "milk")
    }

    @Test("A previous copy that was concealed is not put back")
    func concealedSnapshotNotRestored() async {
      pasteboard.clearContents()
      pasteboard.setString("hunter2", forType: .string)
      pasteboard.setString("", forType: Self.concealed)
      Defaults[.ignoredApps] = ["com.example.Secret"]
      frontmostApp = "com.example.Secret"
      await press(copying: "token")
      #expect(huds == [.ignored])
      // Left as the front app's ⌘C left it.
      #expect(pasteboard.string(forType: .string) == "token")
      #expect(pasteboard.types?.contains(Self.concealed) == false)
    }

    @Test("A previous copy over the size limit isn't kept; the clipboard stays as the front app left it")
    func snapshotOverLimit() async {
      setPrevious(String(repeating: "x", count: 2_000))
      onCopy = { pasteboard in
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: Self.concealed)
      }
      await listCopy.add()
      #expect(huds == [.hiddenContent])
      #expect(pasteboard.string(forType: .string) == "hunter2")
      #expect(History.shared.items.count == 0)
    }

    @Test("The snapshot keeps only the history's types, within the limit, without asking for others")
    func snapshotTypesAndLimit() throws {
      final class LazyProvider: NSObject, NSPasteboardItemDataProvider {
        var asked = false
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
          asked = true
          item.setData(Data(count: 10), forType: type)
        }
      }
      let lazy = LazyProvider()
      let item = NSPasteboardItem()
      item.setString("small", forType: .string)
      item.setDataProvider(lazy, forTypes: [NSPasteboard.PasteboardType("com.example.office-private")])
      pasteboard.clearContents()
      pasteboard.writeObjects([item])

      let snapshot = try #require(PasteboardSnapshot(pasteboard, limit: 100))
      #expect(!lazy.asked)
      #expect(!snapshot.isConcealed)

      snapshot.write(to: pasteboard)
      #expect(pasteboard.string(forType: .string) == "small")
      #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("com.example.office-private")) == false)

      setPrevious(String(repeating: "x", count: 101))
      #expect(PasteboardSnapshot(pasteboard, limit: 100) == nil)
    }

    @Test("Copies from an ignored app are refused")
    func ignoredAppRefused() async {
      Defaults[.ignoredApps] = ["com.example.Secret"]
      frontmostApp = "com.example.Secret"
      setPrevious("previous")
      await press(copying: "token")
      #expect(huds == [.ignored])
      #expect(pasteboard.string(forType: .string) == "previous")
      #expect(History.shared.items.count == 0)
    }

    @Test("Save only from listed apps: other apps are refused")
    func onlyListedApps() async {
      Defaults[.ignoreAllAppsExceptListed] = true
      Defaults[.ignoredApps] = ["com.apple.Notes"]
      await press(copying: "milk")
      #expect(huds == [.ignored])
      frontmostApp = "com.apple.Notes"
      await press(copying: "milk")
      #expect(huds == [.ignored, .newList])
    }

    @Test("Text matching an ignored regular expression is refused")
    func regexpRefused() async {
      Defaults[.ignoreRegexp] = ["^sk-[a-z0-9]+$"]
      await press(copying: "sk-abc123")
      #expect(huds == [.ignored])
      await press(copying: "milk")
      #expect(huds == [.ignored, .newList])
    }

    @Test("While history is paused nothing is added; ignore-only-next is used up")
    func pausedRefused() async {
      Defaults[.ignoreEvents] = true
      Defaults[.ignoreOnlyNextEvent] = true
      await press(copying: "milk")
      #expect(huds == [.paused])
      #expect(!Defaults[.ignoreEvents])
      await press(copying: "milk")
      #expect(huds == [.paused, .newList])
    }

    // MARK: - History changes

    @Test("Clearing the history ends the list; without Clear system clipboard it stays on the clipboard")
    func clearResets() async {
      await press(copying: "milk")
      History.shared.clear()
      #expect(listCopy.session.isEmpty)
      #expect(listCopy.historyItem == nil)
      #expect(listIsOnPasteboard)

      await press(copying: "bread")
      #expect(huds == [.newList, .newList])
      #expect(History.shared.items.toArray().map(\.item.text) == ["bread"])
    }

    @Test("With Clear system clipboard, clearing takes the list off the clipboard")
    func clearTakesListOff() async {
      await press(copying: "milk")
      // What History.clear() does with the setting on, without touching the real clipboard.
      listCopy.reset(clearingPasteboard: true)
      #expect(listCopy.session.isEmpty)
      #expect(!listIsOnPasteboard)
      #expect(pasteboard.types?.isEmpty != false)
    }

    @Test("Deleting the list's history item ends the list and leaves the clipboard alone")
    func deleteResets() async throws {
      await press(copying: "milk")
      let row = try #require(History.shared.items.first)
      let changeCount = pasteboard.changeCount
      History.shared.delete(row)
      #expect(listCopy.session.isEmpty)
      #expect(pasteboard.changeCount == changeCount)
      #expect(listIsOnPasteboard)

      await press(copying: "bread")
      #expect(huds == [.newList, .newList])
      #expect(History.shared.items.toArray().map(\.item.text) == ["bread"])
    }

    @Test("Deleting another item keeps the list")
    func deleteOtherKeepsList() async throws {
      let other = HistoryItem()
      Storage.shared.context.insert(other)
      other.contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("x".utf8))]
      other.title = other.generateTitle()
      let otherRow = History.shared.add(other)
      await press(copying: "milk")
      History.shared.delete(otherRow)
      await press(copying: "bread")
      #expect(huds == [.newList, .added(count: 2)])
    }

    @Test("A pinned list stays as it is; the next press starts a new one")
    func pinnedStartsNewList() async throws {
      await press(copying: "milk")
      let row = try #require(History.shared.items.first)
      History.shared.togglePin(row)
      #expect(row.isPinned)

      await press(copying: "bread")
      #expect(huds == [.newList, .newList])
      #expect(row.item.text == "milk")
    }

    @Test("Choosing the list in the popup ends it")
    func selectingEndsList() async throws {
      await press(copying: "milk")
      let row = try #require(History.shared.items.first)
      ListCopy.willCopy(row.item)
      #expect(listCopy.session.wasPasted)
    }

    // MARK: - Permissions and shortcuts

    @Test("Without Accessibility: an alert, no key press")
    func notTrusted() async {
      trusted = false
      var pressed = false
      onCopy = { _ in pressed = true }
      await listCopy.add()
      #expect(alerts == 1)
      #expect(!pressed)
      #expect(huds.isEmpty)
    }

    @Test("The same shortcut for Open history and Add to list is a duplicate")
    func duplicateShortcut() {
      let shiftCommandC = KeyboardShortcuts.Shortcut(.c, modifiers: [.command, .shift])
      let shiftCommandV = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
      #expect(ListCopy.isDuplicate(shiftCommandC, of: shiftCommandC))
      #expect(!ListCopy.isDuplicate(shiftCommandC, of: shiftCommandV))
      #expect(!ListCopy.isDuplicate(nil, of: nil))
      #expect(!ListCopy.isDuplicate(shiftCommandC, of: nil))
    }

    // MARK: - Helpers

    private var listIsOnPasteboard: Bool {
      pasteboard.types?.contains(.multipastaList) == true
        && listCopy.shouldIgnorePasteboardChange(pasteboard.changeCount)
    }

    /// One press, with the front app copying `text` (nothing when nil).
    private func press(copying text: String?) async {
      onCopy = { pasteboard in
        guard let text else {
          return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
      }
      await listCopy.add()
    }

    private func setPrevious(_ text: String) {
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
    }

    private static let copyImage: (NSPasteboard) -> Void = { pasteboard in
      pasteboard.clearContents()
      pasteboard.setData(NSImage(named: NSImage.addTemplateName)?.tiffRepresentation, forType: .tiff)
    }
  }
}
