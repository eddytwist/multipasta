import AppKit
import Defaults
import Foundation
import Logging
import SwiftData

// Multipasta: imports the clipboard history of upstream Maccy (org.p0deje.Maccy).
//
// Maccy is sandboxed, so its SwiftData store lives in its container. Multipasta is a fork
// with the same models, so the store is opened with our own HistoryItem schema.
// Maccy's files are never opened in place: the store (with its -wal and -shm) is copied
// to a temporary folder first, only the copy is opened (read-only), and the copy is
// removed afterwards. Nothing in Maccy's container is ever written or deleted.
//
// Reading another app's container makes macOS ask once whether Multipasta may access
// data from other apps. Checking whether the store exists does not trigger that prompt.
enum MaccyImporter {
  nonisolated struct Summary: Equatable, Sendable {
    // Items in Maccy's store.
    var found = 0
    // Items added to Multipasta.
    var imported = 0
    // Items whose contents were already in Multipasta (or that had no contents).
    var skipped = 0
    // Items removed afterwards by the history size limit (pinned items are kept).
    var trimmed = 0
  }

  nonisolated enum ImportError: LocalizedError {
    case storeNotFound(URL)
    case accessDenied(URL, underlying: any Error)
    case copyFailed(URL, underlying: any Error)
    case openFailed(underlying: any Error)
    case readFailed(underlying: any Error)
    case multipastaReadFailed(underlying: any Error)
    case saveFailed(underlying: any Error)

    var errorDescription: String? {
      switch self {
      case .storeNotFound:
        return String(localized: "MaccyImportNotFound", table: "MultipastaSettings")
      case .accessDenied:
        return String(localized: "MaccyImportErrorAccessDenied", table: "MultipastaSettings")
      case .copyFailed(_, let error):
        return String(localized: "MaccyImportErrorCopy \(error.localizedDescription)", table: "MultipastaSettings")
      case .openFailed(let error):
        return String(localized: "MaccyImportErrorOpen \(error.localizedDescription)", table: "MultipastaSettings")
      case .readFailed(let error):
        return String(localized: "MaccyImportErrorRead \(error.localizedDescription)", table: "MultipastaSettings")
      case .multipastaReadFailed(let error):
        return String(
          localized: "MaccyImportErrorMultipastaRead \(error.localizedDescription)",
          table: "MultipastaSettings"
        )
      case .saveFailed(let error):
        return String(localized: "MaccyImportErrorSave \(error.localizedDescription)", table: "MultipastaSettings")
      }
    }
  }

  // A temporary copy of Maccy's store. Only this copy is ever opened.
  nonisolated struct Snapshot: Sendable {
    static let fileSuffixes = ["", "-wal", "-shm"]

    let directory: URL
    var storeURL: URL { directory.appending(path: "Storage.sqlite") }

    static func make(of storeURL: URL) throws -> Snapshot {
      let fileManager = FileManager.default
      guard fileManager.fileExists(atPath: storeURL.path(percentEncoded: false)) else {
        throw ImportError.storeNotFound(storeURL)
      }

      let directory = fileManager.temporaryDirectory
        .appending(path: "MultipastaMaccyImport-\(UUID().uuidString)", directoryHint: .isDirectory)
      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        throw ImportError.copyFailed(storeURL, underlying: error)
      }

      let snapshot = Snapshot(directory: directory)
      for suffix in fileSuffixes {
        let source = URL(filePath: storeURL.path(percentEncoded: false) + suffix)
        // The -wal and -shm files exist only while SQLite has not checkpointed.
        guard suffix.isEmpty || fileManager.fileExists(atPath: source.path(percentEncoded: false)) else {
          continue
        }

        let destination = URL(filePath: snapshot.storeURL.path(percentEncoded: false) + suffix)
        do {
          try fileManager.copyItem(at: source, to: destination)
        } catch {
          snapshot.remove()
          throw isPermissionError(error)
            ? ImportError.accessDenied(source, underlying: error)
            : ImportError.copyFailed(source, underlying: error)
        }
      }

      return snapshot
    }

    func remove() {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        MaccyImporter.logger.error(
          "Failed to remove the temporary copy of Maccy's store at \(directory.path): \(String(reflecting: error))"
        )
      }
    }

    private static func isPermissionError(_ error: any Error) -> Bool {
      let error = error as NSError
      if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
        return true
      }
      if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
         underlying.domain == NSPOSIXErrorDomain,
         underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
        return true
      }
      return error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES))
    }
  }

  nonisolated static let logger = Logger(label: "com.eddytwist.Multipasta.MaccyImporter")

  nonisolated static var defaultStoreURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite"
    )
  }

  // A plain existence check: it does not read the file, so macOS does not ask for access.
  nonisolated static func storeExists(at url: URL = defaultStoreURL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  // MARK: - Import

  // Copies Maccy's items from `snapshot` into `context` and saves it.
  // Items whose contents are already in `context` are skipped, using the same check that
  // History uses for duplicates (`HistoryItem.supersedes`). Dates, number of copies,
  // application, title, pin and every content blob are kept. A pin whose key is taken
  // gets another free key, or no key when none is left (as PinManager does).
  @MainActor
  static func importItems(from snapshot: Snapshot, into context: ModelContext) throws -> Summary {
    let container = try openStore(at: snapshot.storeURL)
    let source = ModelContext(container)
    source.autosaveEnabled = false

    var descriptor = FetchDescriptor<HistoryItem>(sortBy: [SortDescriptor(\.firstCopiedAt)])
    descriptor.relationshipKeyPathsForPrefetching = [\.contents]
    let maccyItems: [HistoryItem]
    do {
      maccyItems = try source.fetch(descriptor)
    } catch {
      throw ImportError.readFailed(underlying: error)
    }

    let existingItems: [HistoryItem]
    do {
      existingItems = try context.fetch(FetchDescriptor<HistoryItem>())
    } catch {
      throw ImportError.multipastaReadFailed(underlying: error)
    }

    var duplicates = DuplicateIndex(existingItems)
    var usedPins = Set(existingItems.compactMap(\.pin).filter { !$0.isEmpty })
    var summary = Summary(found: maccyItems.count)

    for maccyItem in maccyItems {
      let contents = maccyItem.contents.filter {
        Clipboard.shared.isPersistable(NSPasteboard.PasteboardType($0.type))
      }
      guard !contents.isEmpty, !duplicates.containsItem(superseding: maccyItem) else {
        summary.skipped += 1
        continue
      }

      // On macOS 14 an item has to be inserted before its relationships are set.
      let item = HistoryItem()
      context.insert(item)
      item.contents = contents.map { HistoryItemContent(type: $0.type, value: $0.value) }
      item.application = maccyItem.application
      item.firstCopiedAt = maccyItem.firstCopiedAt
      item.lastCopiedAt = maccyItem.lastCopiedAt
      item.numberOfCopies = max(1, maccyItem.numberOfCopies)
      item.title = maccyItem.title.containsScalarsUnsafeForTitleLayout
        ? maccyItem.title.removingScalarsUnsafeForTitleLayout()
        : maccyItem.title
      item.pin = assignPin(maccyItem.pin, usedPins: &usedPins)

      duplicates.add(item)
      summary.imported += 1
    }

    guard summary.imported > 0 else {
      return summary
    }

    context.processPendingChanges()
    do {
      try context.save()
    } catch {
      context.rollback()
      throw ImportError.saveFailed(underlying: error)
    }

    return summary
  }

  @MainActor
  private static func openStore(at url: URL) throws -> ModelContainer {
    do {
      return try ModelContainer(
        for: HistoryItem.self,
        configurations: ModelConfiguration(url: url, allowsSave: false, cloudKitDatabase: .none)
      )
    } catch {
      // A read-only store cannot be migrated. This is only the temporary copy,
      // so retry with a writable configuration before giving up.
      let reason = String(reflecting: error)
      logger.warning("Failed to open the copy of Maccy's store read-only at \(url.path), retrying writable: \(reason)")
    }

    do {
      return try ModelContainer(
        for: HistoryItem.self,
        configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
      )
    } catch {
      throw ImportError.openFailed(underlying: error)
    }
  }

  @MainActor
  private static func assignPin(_ pin: String?, usedPins: inout Set<String>) -> String? {
    guard let pin else { return nil }

    let supportedPins = HistoryItem.supportedPins
    if supportedPins.contains(pin), !usedPins.contains(pin) {
      usedPins.insert(pin)
      return pin
    }
    if let freePin = HistoryItem.sortedPins(supportedPins.subtracting(usedPins)).first {
      usedPins.insert(freePin)
      return freePin
    }
    // Pinned, but without a shortcut: every key is taken.
    return ""
  }

  // Finds candidate duplicates by shared contents, then confirms with `supersedes`,
  // so the check is the same as in History without comparing every pair of items.
  private struct DuplicateIndex {
    private struct ContentKey: Hashable {
      let type: String
      let value: Data?
    }

    private var itemsByContent: [ContentKey: [HistoryItem]] = [:]

    init(_ items: [HistoryItem]) {
      items.forEach { add($0) }
    }

    mutating func add(_ item: HistoryItem) {
      for content in item.contents {
        itemsByContent[ContentKey(type: content.type, value: content.value), default: []].append(item)
      }
    }

    func containsItem(superseding item: HistoryItem) -> Bool {
      var checked = Set<ObjectIdentifier>()
      for content in item.contents {
        for candidate in itemsByContent[ContentKey(type: content.type, value: content.value)] ?? []
        where checked.insert(ObjectIdentifier(candidate)).inserted {
          if candidate.supersedes(item) {
            return true
          }
        }
      }
      return false
    }
  }

  // MARK: - Interactive import

  // Shown once after launch when Maccy's store exists. Remembered either way.
  @MainActor
  static func offerImportIfNeeded() {
    guard !Defaults[.maccyImportOffered], storeExists() else { return }

    Defaults[.maccyImportOffered] = true

    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "MaccyImportOfferTitle", table: "MultipastaSettings")
    alert.informativeText = String(localized: "MaccyImportOfferMessage", table: "MultipastaSettings")
    alert.addButton(withTitle: String(localized: "MaccyImportOfferImport", table: "MultipastaSettings"))
    let notNow = alert.addButton(withTitle: String(localized: "MaccyImportOfferNotNow", table: "MultipastaSettings"))
    notNow.keyEquivalent = "\u{1b}"

    guard alert.runModal() == .alertFirstButtonReturn else {
      logger.info("Import from Maccy was offered and postponed")
      return
    }

    Task {
      await importAndReport()
    }
  }

  // Imports into Multipasta's store, applies the history size limit and shows the result.
  @MainActor
  static func importAndReport(from storeURL: URL = defaultStoreURL) async {
    Defaults[.maccyImportOffered] = true

    let result: Result<Summary, any Error>
    do {
      result = .success(try await importIntoStorage(from: storeURL))
    } catch {
      logger.error("Failed to import history from Maccy at \(storeURL.path): \(String(reflecting: error))")
      result = .failure(error)
    }

    showResult(result)
  }

  @MainActor
  private static func importIntoStorage(from storeURL: URL) async throws -> Summary {
    logger.info("Importing history from Maccy at \(storeURL.path)")
    let snapshot = try await Task.detached(priority: .userInitiated) {
      try Snapshot.make(of: storeURL)
    }.value
    defer { snapshot.remove() }

    let context = Storage.shared.context
    var summary = try importItems(from: snapshot, into: context)
    logger.info(
      "Imported \(summary.imported) of \(summary.found) items from Maccy, skipped \(summary.skipped) already present"
    )

    guard summary.imported > 0 else {
      return summary
    }

    // Reload the history: this sorts the new items in and lets the normal size limit
    // remove the oldest unpinned items.
    let countBefore = (try? context.fetchCount(FetchDescriptor<HistoryItem>())) ?? 0
    do {
      try await History.shared.load()
    } catch {
      logger.error("Failed to reload history after importing from Maccy: \(String(reflecting: error))")
    }
    let countAfter = (try? context.fetchCount(FetchDescriptor<HistoryItem>())) ?? countBefore
    summary.trimmed = max(0, countBefore - countAfter)
    if summary.trimmed > 0 {
      logger.info("History size limit removed \(summary.trimmed) items after importing from Maccy")
    }

    return summary
  }

  @MainActor
  private static func showResult(_ result: Result<Summary, any Error>) {
    let alert = NSAlert()

    switch result {
    case .success(let summary) where summary.imported > 0:
      alert.messageText = String(localized: "MaccyImportResultTitle \(summary.imported)", table: "MultipastaSettings")
      var details: [String] = []
      if summary.skipped > 0 {
        details.append(String(localized: "MaccyImportSkipped \(summary.skipped)", table: "MultipastaSettings"))
      }
      if summary.trimmed > 0 {
        details.append(String(localized: "MaccyImportTrimmed \(summary.trimmed)", table: "MultipastaSettings"))
      }
      alert.informativeText = details.joined(separator: " ")
    case .success(let summary) where summary.found > 0:
      alert.messageText = String(localized: "MaccyImportNothingNewTitle", table: "MultipastaSettings")
      alert.informativeText = String(localized: "MaccyImportNothingNewMessage", table: "MultipastaSettings")
    case .success:
      alert.messageText = String(localized: "MaccyImportEmptyTitle", table: "MultipastaSettings")
      alert.informativeText = String(localized: "MaccyImportEmptyMessage", table: "MultipastaSettings")
    case .failure(let error):
      alert.alertStyle = .warning
      alert.messageText = String(localized: "MaccyImportFailedTitle", table: "MultipastaSettings")
      alert.informativeText = error.localizedDescription
    }

    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
