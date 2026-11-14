import SwiftUI

// Multipasta: how a list made by list copy looks in the popup: a small "LIST · N" tag before
// the first line and up to three lines of the list. Other items keep Maccy's one-line title.

/// The title of a history row (HistoryItemView's title closure).
struct ListCopyRowTitle: View {
  nonisolated static let maxLines = 3

  let item: HistoryItemDecorator

  var body: some View {
    if let count = item.item.listEntryCount {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        ListCopyTag(count: count)
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Array(Self.lines(of: item.text).enumerated()), id: \.offset) { _, line in
            Text(verbatim: line)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      }
      .padding(.vertical, 4)
    } else {
      Text(verbatim: item.title)
    }
  }

  /// The first lines of the list, at most `maxLines`.
  nonisolated static func lines(of text: String) -> [String] {
    var lines: [String] = []
    text.enumerateLines { line, stop in
      lines.append(line)
      if lines.count == maxLines {
        stop = true
      }
    }
    return lines.isEmpty ? [text] : lines
  }

  /// VoiceOver: "List, 3 items" before the usual description of the row.
  static func accessibilityLabel(for item: HistoryItemDecorator) -> String {
    guard let count = item.item.listEntryCount else {
      return item.accessibilityLabel
    }
    let format = NSLocalizedString("ListRowAccessibility %lld", tableName: "MultipastaSettings", comment: "")
    return String.localizedStringWithFormat(format, count) + ", " + item.accessibilityLabel
  }
}

/// "LIST · 3" in small capitals on a faint rounded background; follows the row's text colour,
/// so it stays readable on the selection highlight.
struct ListCopyTag: View {
  let count: Int

  var body: some View {
    // At least as wide as a two-digit count, so the lines of rows with 9 and 10 entries
    // start at the same place.
    ZStack(alignment: .leading) {
      label(Text("ListTag \(88)", tableName: "MultipastaSettings"))
        .hidden()
      label(Text("ListTag \(count)", tableName: "MultipastaSettings"))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 5)
    .padding(.vertical, 1.5)
    .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }

  private func label(_ text: Text) -> some View {
    text
      .font(.system(size: 9.5, weight: .semibold))
      .monospacedDigit()
      .kerning(0.4)
      .lineLimit(1)
      .fixedSize()
  }
}
