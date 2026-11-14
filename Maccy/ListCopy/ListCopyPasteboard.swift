import AppKit

// Multipasta: how list copy puts a list on the clipboard and recognises it in the history.

extension NSPasteboard.PasteboardType {
  /// Marks a list: on the clipboard and in the history item's contents. The value is the
  /// number of entries as a decimal string, so the "LIST · N" tag survives restarts.
  nonisolated static let multipastaList = NSPasteboard.PasteboardType(rawValue: "com.eddytwist.Multipasta.list")
}

extension HistoryItem {
  /// The number of entries when this history item is a list made by list copy, nil otherwise.
  var listEntryCount: Int? {
    guard let content = contents.first(where: { $0.type == NSPasteboard.PasteboardType.multipastaList.rawValue }),
          let data = content.value,
          let string = String(data: data, encoding: .utf8),
          let count = Int(string),
          count > 0 else {
      return nil
    }
    return count
  }
}

/// Provides a list's text lazily: the string is handed over only when some app asks for it,
/// and that request is how list copy learns the list was pasted.
///
/// Multipasta itself never asks for it: the clipboard watcher skips the item that list copy
/// wrote (see `ListCopy.shouldIgnorePasteboardChange`).
nonisolated final class ListPasteboardProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
  let text: String
  let token: UInt64
  private let onRequest: @Sendable (UInt64) -> Void
  private let lock = NSLock()
  private var provided = false

  init(text: String, token: UInt64, onRequest: @escaping @Sendable (UInt64) -> Void) {
    self.text = text
    self.token = token
    self.onRequest = onRequest
  }

  /// Whether some app has received the text already.
  var hasProvided: Bool {
    lock.withLock { provided }
  }

  func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
    item.setString(text, forType: type)
    lock.withLock { provided = true }
    onRequest(token)
  }

  func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

  /// A pasteboard item whose string comes from `provider` on request and that carries the
  /// list marker with `count` right away.
  static func item(provider: ListPasteboardProvider, count: Int) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(String(count), forType: .multipastaList)
    item.setDataProvider(provider, forTypes: [.string])
    return item
  }
}
