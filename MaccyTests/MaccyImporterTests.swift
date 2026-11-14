import AppKit
import Foundation
import SwiftData
import Testing
@testable import Maccy

@MainActor
@Suite("Import from Maccy")
struct MaccyImporterTests {
  private let directory: URL
  private var sourceURL: URL { directory.appending(path: "Maccy/Storage.sqlite") }
  private var targetURL: URL { directory.appending(path: "Multipasta/Storage.sqlite") }

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "MaccyImporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory.appending(path: "Maccy"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: directory.appending(path: "Multipasta"),
      withIntermediateDirectories: true
    )
  }

  @Test("Imports items, pins, dates and images, and skips duplicates")
  func importsHistory() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = try pngData()

    // A Maccy store built with the same models.
    try withContext(at: sourceURL) { context in
      insert(into: context, string: "foo", first: 1_000, last: 2_000, copies: 3, application: "Safari.app")
      insert(into: context, string: "bar", first: 1_100, last: 2_100, copies: 1, pin: "b", title: "Bar title")
      insert(
        into: context,
        contents: [(NSPasteboard.PasteboardType.png.rawValue, png)],
        first: 1_200,
        last: 2_200,
        copies: 5,
        pin: "c"
      )
      insert(into: context, string: "already here", first: 1_300, last: 2_300, copies: 2)
    }

    // Multipasta already has one of Maccy's items and uses pin "c".
    let target = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: targetURL))
    let context = ModelContext(target)
    insert(into: context, string: "already here", first: 5_000, last: 6_000, copies: 1)
    insert(into: context, string: "pinned in Multipasta", first: 5_100, last: 6_100, copies: 1, pin: "c")
    try context.save()

    let summary = try importOnce(into: context)
    #expect(summary == MaccyImporter.Summary(found: 4, imported: 3, skipped: 1))

    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    #expect(items.count == 5)
    #expect(try context.fetchCount(FetchDescriptor<HistoryItemContent>()) == 5)

    let foo = try #require(items.first { $0.text == "foo" })
    #expect(foo.firstCopiedAt == Date(timeIntervalSince1970: 1_000))
    #expect(foo.lastCopiedAt == Date(timeIntervalSince1970: 2_000))
    #expect(foo.numberOfCopies == 3)
    #expect(foo.application == "Safari.app")
    #expect(foo.pin == nil)

    let bar = try #require(items.first { $0.text == "bar" })
    #expect(bar.pin == "b")
    #expect(bar.title == "Bar title")

    // The image keeps its bytes; its pin key was taken, so it gets another free one.
    let image = try #require(items.first { $0.imageData != nil })
    #expect(image.imageData == png)
    #expect(image.image != nil)
    #expect(image.numberOfCopies == 5)
    #expect(image.firstCopiedAt == Date(timeIntervalSince1970: 1_200))
    let imagePin = try #require(image.pin)
    #expect(imagePin != "c")
    #expect(imagePin != "b")
    #expect(HistoryItem.supportedPins.contains(imagePin))

    // The duplicate was skipped: Multipasta's own item is unchanged.
    let duplicates = items.filter { $0.text == "already here" }
    #expect(duplicates.count == 1)
    #expect(duplicates.first?.firstCopiedAt == Date(timeIntervalSince1970: 5_000))

    // Importing again adds nothing.
    let again = try importOnce(into: context)
    #expect(again == MaccyImporter.Summary(found: 4, imported: 0, skipped: 4))
    #expect(try context.fetchCount(FetchDescriptor<HistoryItem>()) == 5)

    // Maccy's store is untouched.
    try withContext(at: sourceURL) { source in
      let count = try source.fetchCount(FetchDescriptor<HistoryItem>())
      #expect(count == 4)
    }
  }

  @Test("Removes the temporary copy")
  func removesSnapshot() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try withContext(at: sourceURL) { context in
      insert(into: context, string: "foo", first: 1_000, last: 2_000, copies: 1)
    }

    let snapshot = try MaccyImporter.Snapshot.make(of: sourceURL)
    #expect(snapshot.directory.path != sourceURL.deletingLastPathComponent().path)
    #expect(FileManager.default.fileExists(atPath: snapshot.storeURL.path(percentEncoded: false)))
    snapshot.remove()
    #expect(!FileManager.default.fileExists(atPath: snapshot.directory.path(percentEncoded: false)))
    #expect(MaccyImporter.storeExists(at: sourceURL))
  }

  @Test("Reports a missing store")
  func missingStore() {
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!MaccyImporter.storeExists(at: sourceURL))
    #expect {
      try MaccyImporter.Snapshot.make(of: sourceURL)
    } throws: { error in
      guard case .storeNotFound = error as? MaccyImporter.ImportError else { return false }
      return true
    }
  }

  // MARK: - Helpers

  private func importOnce(into context: ModelContext) throws -> MaccyImporter.Summary {
    let snapshot = try MaccyImporter.Snapshot.make(of: sourceURL)
    defer { snapshot.remove() }
    return try MaccyImporter.importItems(from: snapshot, into: context)
  }

  private func withContext(at url: URL, _ body: (ModelContext) throws -> Void) throws {
    let container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: url))
    let context = ModelContext(container)
    try body(context)
    if context.hasChanges {
      try context.save()
    }
  }

  @discardableResult
  private func insert(
    into context: ModelContext,
    string: String,
    first: TimeInterval,
    last: TimeInterval,
    copies: Int,
    pin: String? = nil,
    application: String? = nil,
    title: String? = nil
  ) -> HistoryItem {
    insert(
      into: context,
      contents: [(NSPasteboard.PasteboardType.string.rawValue, Data(string.utf8))],
      first: first,
      last: last,
      copies: copies,
      pin: pin,
      application: application,
      title: title ?? string
    )
  }

  @discardableResult
  private func insert(
    into context: ModelContext,
    contents: [(String, Data)],
    first: TimeInterval,
    last: TimeInterval,
    copies: Int,
    pin: String? = nil,
    application: String? = nil,
    title: String = ""
  ) -> HistoryItem {
    let item = HistoryItem()
    context.insert(item)
    item.contents = contents.map { HistoryItemContent(type: $0.0, value: $0.1) }
    item.firstCopiedAt = Date(timeIntervalSince1970: first)
    item.lastCopiedAt = Date(timeIntervalSince1970: last)
    item.numberOfCopies = copies
    item.pin = pin
    item.application = application
    item.title = title
    return item
  }

  private func pngData() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 4,
      pixelsHigh: 4,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))
    bitmap.setColor(.systemRed, atX: 1, y: 1)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
