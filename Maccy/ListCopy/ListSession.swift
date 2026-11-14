import Defaults
import Foundation

// Multipasta: list copy.
//
// The add-to-list shortcut copies the selected text and appends it to a list; the whole list
// sits on the clipboard and in the history as one item. This file holds the decisions only
// (when a list starts, how an entry is cleaned up, how the list is written out), with no
// pasteboard, history or windows, so it can be unit-tested. ListCopy.swift does the rest.

/// How the entries of a list are joined into the text that goes on the clipboard.
nonisolated enum ListFormat: String, CaseIterable, Identifiable, Defaults.Serializable {
  /// One entry per line.
  case plain
  /// "• " before each entry.
  case bullets
  /// "1. ", "2. ", … before each entry.
  case numbered

  var id: Self { self }

  /// Entries joined with "\n". In the bulleted and numbered formats the further lines of a
  /// multi-line entry are indented under its first line, so the entry still reads as one item.
  func compose(_ entries: [String]) -> String {
    entries.enumerated().map { index, entry in
      let prefix = self.prefix(at: index)
      guard !prefix.isEmpty else {
        return entry
      }
      let indent = String(repeating: " ", count: prefix.count)
      return prefix + entry.replacingOccurrences(of: "\n", with: "\n" + indent)
    }
    .joined(separator: "\n")
  }

  private func prefix(at index: Int) -> String {
    switch self {
    case .plain:
      return ""
    case .bullets:
      return "• "
    case .numbered:
      return "\(index + 1). "
    }
  }
}

/// After how long without additions the next one starts a new list.
nonisolated enum ListTimeout: Int, CaseIterable, Identifiable, Defaults.Serializable {
  case fiveMinutes = 5
  case fifteenMinutes = 15
  case thirtyMinutes = 30
  case oneHour = 60
  case never = 0

  var id: Self { self }

  /// Nil for `.never`.
  var interval: TimeInterval? {
    self == .never ? nil : TimeInterval(rawValue * 60)
  }
}

/// The list being collected: its entries, when the last one was added and whether it has been
/// pasted since.
nonisolated struct ListSession: Equatable {
  enum AddResult: Equatable {
    /// Nothing but whitespace: the list is unchanged.
    case ignored
    /// Appended; `count` entries now. `startedNewList` is true when the previous list was
    /// dropped first (no list yet, pasted, or timed out).
    case added(count: Int, startedNewList: Bool)
  }

  private(set) var entries: [String] = []
  private(set) var lastAddedAt: Date?
  private(set) var wasPasted = false

  var count: Int { entries.count }
  var isEmpty: Bool { entries.isEmpty }

  /// Whether an addition at `date` starts a new list.
  func startsNewList(at date: Date, timeout: TimeInterval?) -> Bool {
    guard !entries.isEmpty, let lastAddedAt else {
      return true
    }
    if wasPasted {
      return true
    }
    if let timeout, date.timeIntervalSince(lastAddedAt) >= timeout {
      return true
    }
    return false
  }

  mutating func add(_ text: String, at date: Date, timeout: TimeInterval?) -> AddResult {
    guard let entry = Self.normalize(text) else {
      return .ignored
    }

    let startsNew = startsNewList(at: date, timeout: timeout)
    if startsNew {
      entries = []
      wasPasted = false
    }
    entries.append(entry)
    lastAddedAt = date
    return .added(count: entries.count, startedNewList: startsNew)
  }

  /// The list was pasted: the next addition starts a new one.
  mutating func markPasted() {
    guard !entries.isEmpty else {
      return
    }
    wasPasted = true
  }

  /// Forgets the list: the next addition starts a new one.
  mutating func reset() {
    self = ListSession()
  }

  func text(format: ListFormat) -> String {
    format.compose(entries)
  }

  /// An entry as it goes into the list: line breaks unified to "\n", blank lines before the
  /// text dropped, trailing whitespace and line breaks trimmed. Leading spaces on the first
  /// line stay (indentation in code). Nil when nothing is left.
  static func normalize(_ text: String) -> String? {
    var lines = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")

    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeFirst()
    }

    let joined = lines.joined(separator: "\n")
    guard let lastIndex = joined.lastIndex(where: { !$0.isWhitespace && !$0.isNewline }) else {
      return nil
    }
    return String(joined[...lastIndex])
  }
}
