import Defaults
import SwiftUI

// Multipasta: the "Lists" section of Settings → History → Advanced… (list copy).
struct ListCopySettingsSection: View {
  @Default(.listFormat) private var listFormat
  @Default(.listTimeout) private var listTimeout

  var body: some View {
    Section {
      Picker(selection: $listFormat) {
        ForEach(ListFormat.allCases) { format in
          Self.label(for: format)
        }
      } label: {
        Text("ListFormat", tableName: "MultipastaSettings")
      }

      Picker(selection: $listTimeout) {
        ForEach(ListTimeout.allCases) { timeout in
          Self.label(for: timeout)
        }
      } label: {
        Text("ListTimeout", tableName: "MultipastaSettings")
      }
    } header: {
      Text("Lists", tableName: "MultipastaSettings")
    } footer: {
      SectionFooter(Text("ListsCaption", tableName: "MultipastaSettings"))
    }
  }

  // Text views rather than strings, so that the labels follow the view's locale.
  private static func label(for format: ListFormat) -> Text {
    switch format {
    case .plain:
      return Text("ListFormatPlain", tableName: "MultipastaSettings")
    case .bullets:
      return Text("ListFormatBullets", tableName: "MultipastaSettings")
    case .numbered:
      return Text("ListFormatNumbered", tableName: "MultipastaSettings")
    }
  }

  private static func label(for timeout: ListTimeout) -> Text {
    switch timeout {
    case .never:
      return Text("ListTimeoutNever", tableName: "MultipastaSettings")
    case .oneHour:
      return Text("ListTimeoutHour", tableName: "MultipastaSettings")
    default:
      return Text("ListTimeoutMinutes \(timeout.rawValue)", tableName: "MultipastaSettings")
    }
  }
}

#Preview {
  Form {
    ListCopySettingsSection()
  }
  .formStyle(.grouped)
  .frame(width: SettingsLayout.width)
}
