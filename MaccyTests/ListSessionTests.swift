import Foundation
import Testing
@testable import Maccy

@Suite("List copy session")
final class ListSessionTests {
  static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
  static let fifteenMinutes = ListTimeout.fifteenMinutes.interval

  var session = ListSession()

  @Test("The first addition starts a new list")
  func firstAdditionStartsList() {
    #expect(session.add("milk", at: Self.start, timeout: Self.fifteenMinutes) == .added(count: 1, startedNewList: true))
    #expect(session.entries == ["milk"])
    #expect(session.count == 1)
  }

  @Test("Further additions append, one entry each")
  func appends() {
    _ = session.add("milk", at: Self.start, timeout: Self.fifteenMinutes)
    let result = session.add("call the bank", at: Self.start.addingTimeInterval(60), timeout: Self.fifteenMinutes)
    #expect(result == .added(count: 2, startedNewList: false))
    _ = session.add("parcel", at: Self.start.addingTimeInterval(120), timeout: Self.fifteenMinutes)
    #expect(session.entries == ["milk", "call the bank", "parcel"])
    #expect(session.count == 3)
    #expect(session.text(format: .plain) == "milk\ncall the bank\nparcel")
  }

  @Test("Trailing whitespace and line breaks are trimmed")
  func trimsTrailingWhitespace() {
    _ = session.add("milk  \n\n", at: Self.start, timeout: Self.fifteenMinutes)
    _ = session.add("bread\t \r\n", at: Self.start, timeout: Self.fifteenMinutes)
    #expect(session.entries == ["milk", "bread"])
  }

  @Test("Blank lines before the text go, indentation of the first line stays")
  func dropsLeadingBlankLines() {
    _ = session.add("\n  \n    let x = 1\n", at: Self.start, timeout: Self.fifteenMinutes)
    #expect(session.entries == ["    let x = 1"])
  }

  @Test("A multi-line selection is one entry")
  func multiLineBlock() {
    _ = session.add("first", at: Self.start, timeout: Self.fifteenMinutes)
    let result = session.add("line a\r\nline b\n\nline c\n", at: Self.start, timeout: Self.fifteenMinutes)
    #expect(result == .added(count: 2, startedNewList: false))
    #expect(session.entries == ["first", "line a\nline b\n\nline c"])
    #expect(session.text(format: .plain) == "first\nline a\nline b\n\nline c")
  }

  @Test("Empty or whitespace-only input is ignored", arguments: ["", " ", "\n\n", " \t\r\n "])
  func ignoresEmptyInput(input: String) {
    _ = session.add("milk", at: Self.start, timeout: Self.fifteenMinutes)
    #expect(session.add(input, at: Self.start, timeout: Self.fifteenMinutes) == .ignored)
    #expect(session.entries == ["milk"])
  }

  @Test("Empty input doesn't start a list")
  func emptyInputOnEmptySession() {
    #expect(session.add("  ", at: Self.start, timeout: Self.fifteenMinutes) == .ignored)
    #expect(session.isEmpty)
    #expect(session.lastAddedAt == nil)
  }

  @Test("After the list is pasted the next addition starts a new list")
  func newListAfterPaste() {
    _ = session.add("milk", at: Self.start, timeout: Self.fifteenMinutes)
    _ = session.add("bread", at: Self.start, timeout: Self.fifteenMinutes)
    session.markPasted()
    #expect(session.wasPasted)
    let result = session.add("eggs", at: Self.start.addingTimeInterval(5), timeout: Self.fifteenMinutes)
    #expect(result == .added(count: 1, startedNewList: true))
    #expect(session.entries == ["eggs"])
    #expect(!session.wasPasted)
  }

  @Test("Pasting with no list changes nothing")
  func markPastedOnEmptySession() {
    session.markPasted()
    #expect(!session.wasPasted)
  }

  @Test("After the timeout the next addition starts a new list")
  func newListAfterTimeout() {
    _ = session.add("milk", at: Self.start, timeout: Self.fifteenMinutes)
    let justBefore = Self.start.addingTimeInterval(15 * 60 - 1)
    #expect(session.add("bread", at: justBefore, timeout: Self.fifteenMinutes) == .added(count: 2, startedNewList: false))
    // The timeout counts from the last addition.
    let afterTimeout = justBefore.addingTimeInterval(15 * 60)
    #expect(session.add("eggs", at: afterTimeout, timeout: Self.fifteenMinutes) == .added(count: 1, startedNewList: true))
    #expect(session.entries == ["eggs"])
  }

  static let timeoutCases: [(ListTimeout, TimeInterval)] = [
    (.fiveMinutes, 300),
    (.fifteenMinutes, 900),
    (.thirtyMinutes, 1_800),
    (.oneHour, 3_600)
  ]

  @Test("Each timeout setting", arguments: timeoutCases)
  func timeouts(timeout: ListTimeout, seconds: TimeInterval) {
    #expect(timeout.interval == seconds)
    _ = session.add("milk", at: Self.start, timeout: timeout.interval)
    #expect(!session.startsNewList(at: Self.start.addingTimeInterval(seconds - 1), timeout: timeout.interval))
    #expect(session.startsNewList(at: Self.start.addingTimeInterval(seconds), timeout: timeout.interval))
  }

  @Test("With Never the list doesn't time out")
  func neverTimesOut() {
    #expect(ListTimeout.never.interval == nil)
    _ = session.add("milk", at: Self.start, timeout: ListTimeout.never.interval)
    let muchLater = Self.start.addingTimeInterval(30 * 24 * 60 * 60)
    #expect(session.add("bread", at: muchLater, timeout: ListTimeout.never.interval) == .added(count: 2, startedNewList: false))
    // Pasting still ends it.
    session.markPasted()
    #expect(session.add("eggs", at: muchLater, timeout: ListTimeout.never.interval) == .added(count: 1, startedNewList: true))
  }

  @Test("Reset forgets the list")
  func reset() {
    _ = session.add("milk", at: Self.start, timeout: Self.fifteenMinutes)
    session.reset()
    #expect(session.isEmpty)
    #expect(session.add("bread", at: Self.start, timeout: Self.fifteenMinutes) == .added(count: 1, startedNewList: true))
  }

  @Test("Formats")
  func formats() {
    let entries = ["milk", "call the bank", "parcel"]
    #expect(ListFormat.plain.compose(entries) == "milk\ncall the bank\nparcel")
    #expect(ListFormat.bullets.compose(entries) == "• milk\n• call the bank\n• parcel")
    #expect(ListFormat.numbered.compose(entries) == "1. milk\n2. call the bank\n3. parcel")
    #expect(ListFormat.plain.compose([]) == "")
  }

  @Test("Multi-line entries are indented under their bullet or number")
  func formatsMultiLineEntries() {
    let entries = ["one", "two a\ntwo b"]
    #expect(ListFormat.plain.compose(entries) == "one\ntwo a\ntwo b")
    #expect(ListFormat.bullets.compose(entries) == "• one\n• two a\n  two b")
    #expect(ListFormat.numbered.compose(entries) == "1. one\n2. two a\n   two b")
  }

  @Test("Numbers past 9 keep counting")
  func numberedPastNine() {
    let entries = (1...10).map { "item \($0)" }
    let lines = ListFormat.numbered.compose(entries).components(separatedBy: "\n")
    #expect(lines.first == "1. item 1")
    #expect(lines.last == "10. item 10")
  }

  @Test("The list's text follows the format")
  func sessionText() {
    _ = session.add("milk", at: Self.start, timeout: Self.fifteenMinutes)
    _ = session.add("bread", at: Self.start, timeout: Self.fifteenMinutes)
    #expect(session.text(format: .bullets) == "• milk\n• bread")
    #expect(session.text(format: .numbered) == "1. milk\n2. bread")
  }

  @Test("Popup rows show at most three lines")
  func rowLines() {
    #expect(ListCopyRowTitle.lines(of: "a\nb\nc\nd") == ["a", "b", "c"])
    #expect(ListCopyRowTitle.lines(of: "a\nb") == ["a", "b"])
    #expect(ListCopyRowTitle.lines(of: "a") == ["a"])
  }
}
