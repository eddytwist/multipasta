import AppKit
import Defaults
import Testing
@testable import Maccy

extension SharedStateTests {
  // The history side of list copy: one item per list, rewritten in place.
  @MainActor
  final class ListCopyHistoryTests {
    let savedSortBy = Defaults[.sortBy]
    let history = History.shared

    init() {
      History.shared.clearAll()
      Defaults[.sortBy] = .lastCopiedAt
    }

    deinit {
      Defaults[.sortBy] = savedSortBy
    }

    @Test("The list marker gives the entry count")
    func listEntryCount() {
      #expect(item("milk\nbread", listCount: 2).listEntryCount == 2)
      #expect(item("milk", listCount: nil).listEntryCount == nil)
      #expect(item("milk", listCount: 0).listEntryCount == nil)
    }

    @Test("Updating in place keeps one item and moves it to the top")
    func updateInPlace() throws {
      let list = history.add(item("milk", listCount: 1, at: Date(timeIntervalSinceNow: -60)))
      let other = history.add(item("https://example.com", listCount: nil, at: Date(timeIntervalSinceNow: -30)))
      #expect(history.items.toArray() == [other, list])

      let updated = history.updateInPlace(list.item) { item in
        item.contents.forEach(Storage.shared.context.delete)
        item.contents = Self.contents("milk\nbread", listCount: 2)
        item.lastCopiedAt = .now
        item.title = item.generateTitle()
      }

      #expect(updated)
      #expect(history.items.toArray() == [list, other])
      #expect(list.item.listEntryCount == 2)
      #expect(list.item.text == "milk\nbread")
      #expect(list.title == list.item.title)
      #expect(history.items.count == 2)
    }

    @Test("An item that left the history isn't updated")
    func updateDeletedItem() {
      let list = history.add(item("milk", listCount: 1))
      history.delete(list)
      var called = false
      let updated = history.updateInPlace(list.item) { _ in called = true }
      #expect(!updated)
      #expect(!called)
    }

    @Test("The watcher ignores clipboard changes list copy didn't make only when told")
    func watcherHook() {
      // Nothing written by list copy in unit tests: ordinary changes are not ignored.
      #expect(!ListCopy.shared.shouldIgnorePasteboardChange(NSPasteboard.general.changeCount))
    }

    private func item(_ text: String, listCount: Int?, at date: Date = .now) -> HistoryItem {
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = Self.contents(text, listCount: listCount)
      item.lastCopiedAt = date
      item.firstCopiedAt = date
      item.title = item.generateTitle()
      return item
    }

    private static func contents(_ text: String, listCount: Int?) -> [HistoryItemContent] {
      var contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))]
      if let listCount {
        contents.append(
          HistoryItemContent(
            type: NSPasteboard.PasteboardType.multipastaList.rawValue,
            value: Data(String(listCount).utf8)
          )
        )
      }
      return contents
    }
  }
}
