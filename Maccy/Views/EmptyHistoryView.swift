import SwiftUI

// Multipasta: one grey line shown in the popup when there is nothing to list,
// either because the history is empty or because the search found nothing.
struct EmptyHistoryView: View {
  var isSearching: Bool

  var body: some View {
    Text(LocalizedStringKey(isSearching ? "no_matches" : "empty_history"))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, minHeight: Popup.itemHeight, alignment: .leading)
      .padding(.horizontal, 10)
      .accessibilityIdentifier("empty-history")
  }
}

#Preview {
  VStack {
    EmptyHistoryView(isSearching: false)
    EmptyHistoryView(isSearching: true)
  }
  .frame(width: 300)
}
