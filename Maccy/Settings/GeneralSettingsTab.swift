import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin

// Multipasta: the "General" tab of the settings window.
// Maccy's own GeneralSettingsPane is kept untouched to keep upstream merges cheap;
// the settings it had that are not shown here live in AdvancedSettingsSheet.
struct GeneralSettingsTab: View {
  /// README screenshots leave the version out, so they don't go stale with every release.
  private static var hidesVersion: Bool {
    #if DEBUG
    return AppDelegate.readmeScreenshotAppearance != nil
    #else
    return false
    #endif
  }

  static let maccyURL = URL(string: "https://github.com/p0deje/Maccy")!

  private var appName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? "Multipasta"
  }

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  // Multipasta: set when Add to list was turned off for having Open history's shortcut.
  @Default(.addToListTurnedOffAsDuplicate) private var addToListTurnedOff

  var body: some View {
    Form {
      Section {
        // Mirrors GeneralSettingsPane.swift ("Open" recorder).
        KeyboardShortcuts.Recorder(for: .popup, onChange: { newShortcut in
          if newShortcut == nil {
            // No shortcut is recorded. Remove keys monitor
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            // User is using shortcut. Ensure keys monitor is initialized
            AppState.shared.popup.initEventsMonitor()
          }
        }) {
          Text("OpenHistory", tableName: "MultipastaSettings")
        }
        // Multipasta: one combination can't open the history and add to the list.
        .shortcutValidation { shortcut in
          ListCopy.isDuplicate(shortcut, of: KeyboardShortcuts.getShortcut(for: .addToList))
            ? .disallow(reason: NSLocalizedString("ShortcutUsedByAddToList", tableName: "MultipastaSettings", comment: ""))
            : .allow
        }
        .help(Text("OpenTooltip", tableName: "GeneralSettings"))

        // Multipasta: list copy (Maccy/ListCopy).
        KeyboardShortcuts.Recorder(for: .addToList, onChange: { _ in
          addToListTurnedOff = false
        }) {
          Text("AddToList", tableName: "MultipastaSettings")
          if addToListTurnedOff {
            Text("AddToListTurnedOff", tableName: "MultipastaSettings")
          }
        }
        .shortcutValidation { shortcut in
          ListCopy.isDuplicate(shortcut, of: KeyboardShortcuts.getShortcut(for: .popup))
            ? .disallow(reason: NSLocalizedString("ShortcutUsedByOpenHistory", tableName: "MultipastaSettings", comment: ""))
            : .allow
        }
        .help(Text("AddToListTooltip", tableName: "MultipastaSettings"))

        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteOnEnter", tableName: "MultipastaSettings")
          Text("PasteOnEnterCaption", tableName: "MultipastaSettings")
        }

        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "MultipastaSettings")
        }
      }

      Section {
        LabeledContent {
          Link(destination: Self.maccyURL) {
            Text("MaccyOnGitHub", tableName: "MultipastaSettings")
          }
          .help(Self.maccyURL.absoluteString)
        } label: {
          if Self.hidesVersion {
            Text("BasedOnMaccyLine", tableName: "MultipastaSettings")
          } else {
            Text("VersionLine \(version)", tableName: "MultipastaSettings")
          }
        }

        HStack {
          Spacer()
          Button {
            AppState.shared.openAbout()
          } label: {
            Text("AboutApp \(appName)", tableName: "MultipastaSettings")
          }
        }
      } header: {
        Text("About", tableName: "MultipastaSettings")
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .frame(width: SettingsLayout.width)
    .fixedSize(horizontal: false, vertical: true)
    // The note about Add to list is shown once.
    .onDisappear {
      addToListTurnedOff = false
    }
  }
}

// Shared metrics for the Multipasta settings tabs.
enum SettingsLayout {
  static let width: CGFloat = 500
}

#Preview {
  GeneralSettingsTab()
    .environment(\.locale, .init(identifier: "en"))
}
