import SwiftUI
import Defaults

// Multipasta: the "History" tab of the settings window.
// Everything else Maccy exposes is in AdvancedSettingsSheet behind the "Advanced…" button.
struct HistorySettingsTab: View {
  @Default(.size) private var size

  @State private var storage = StorageSettingsPane.ViewModel()
  @State private var storageSize = Storage.shared.size
  @State private var showAdvanced = false

  private static let sizePresets = [100, 200, 500, 999]

  // Presets plus the stored value when it is something else (set in Maccy or via
  // `defaults write`), so that opening Settings never changes it.
  private var sizeOptions: [Int] {
    Self.sizePresets.contains(size) ? Self.sizePresets : (Self.sizePresets + [size]).sorted()
  }

  var body: some View {
    Form {
      Section {
        Picker(selection: $size) {
          ForEach(sizeOptions, id: \.self) { option in
            Text("HistorySizeOption \(option)", tableName: "MultipastaSettings")
              .tag(option)
          }
        } label: {
          Text("HistorySize", tableName: "MultipastaSettings")
          if !storageSize.isEmpty {
            Text(verbatim: storageSize)
              .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
          }
        }
        .help(Text("SizeTooltip", tableName: "StorageSettings"))
        .onAppear {
          storageSize = Storage.shared.size
        }

        Toggle(isOn: $storage.saveImages) {
          Text("Images", tableName: "MultipastaSettings")
          Text("ImagesCaption", tableName: "MultipastaSettings")
        }
      }

      IgnoredAppsSection()
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button {
          showAdvanced = true
        } label: {
          Text("Advanced", tableName: "MultipastaSettings")
        }
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(width: SettingsLayout.width)
    .sheet(isPresented: $showAdvanced) {
      AdvancedSettingsSheet()
    }
  }
}

// Multipasta: "Don't save from these apps" as a table with +/− buttons.
// Mirrors Maccy's IgnoreApplicationsSettingsView (same `ignoredApps` and
// `ignoreAllAppsExceptListed` keys). With `ignoreAllAppsExceptListed` on, the same
// list means "save only from these apps", so the title follows that setting.
struct IgnoredAppsSection: View {
  @Default(.ignoredApps) private var ignoredApps
  @Default(.ignoreAllAppsExceptListed) private var onlyListed

  @State private var isAdding = false
  @State private var selection: String?

  var body: some View {
    Section {
      List(selection: $selection) {
        ForEach(ignoredApps, id: \.self) { app in
          IgnoredAppRow(bundleIdentifier: app)
            .tag(app)
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: false))
      .overlay {
        if ignoredApps.isEmpty {
          Text(onlyListed ? "AllowedAppsEmpty" : "IgnoredAppsEmpty", tableName: "MultipastaSettings")
            .foregroundStyle(.secondary)
        }
      }
      .frame(height: 112)
      .onDeleteCommand {
        remove(selection)
      }

      HStack(spacing: 0) {
        Button {
          isAdding = true
        } label: {
          Image(systemName: "plus")
            .frame(width: 20, height: 16)
        }
        .accessibilityLabel(Text("AddApp", tableName: "MultipastaSettings"))
        .help(Text("AddApp", tableName: "MultipastaSettings"))

        Button {
          remove(selection)
        } label: {
          Image(systemName: "minus")
            .frame(width: 20, height: 16)
        }
        .disabled(selection == nil)
        .accessibilityLabel(Text("RemoveApp", tableName: "MultipastaSettings"))
        .help(Text("RemoveApp", tableName: "MultipastaSettings"))

        Spacer()
      }
      .buttonStyle(.borderless)
      .fileDialogDefaultDirectory(URL(string: "/Applications"))
      .fileImporter(
        isPresented: $isAdding,
        allowedContentTypes: [.application]
      ) { result in
        switch result {
        case .success(let appUrl):
          // Kept from Maccy, where the app is sandboxed and apps outside /Applications
          // can only be read through the security-scoped URL. Multipasta is not
          // sandboxed, so this is a no-op here; it stays to keep upstream merges simple.
          let isAccessing = appUrl.startAccessingSecurityScopedResource()
          defer {
            if isAccessing {
              appUrl.stopAccessingSecurityScopedResource()
            }
          }

          if let bundle = Bundle(path: appUrl.path),
             let bundleIdentifier = bundle.bundleIdentifier,
             !ignoredApps.contains(bundleIdentifier) {
            ignoredApps.append(bundleIdentifier)
          }
        case .failure(let error):
          print("Failed to select application: \(error)")
        }
      }
    } header: {
      Text(onlyListed ? "AllowedApps" : "IgnoredApps", tableName: "MultipastaSettings")
    } footer: {
      VStack(alignment: .leading, spacing: 2) {
        Toggle(isOn: $onlyListed) {
          Text("IgnoreAllExceptListed", tableName: "MultipastaSettings")
        }
        .toggleStyle(.checkbox)

        Text("IgnoreAllExceptListedCaption", tableName: "MultipastaSettings")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 20)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func remove(_ app: String?) {
    guard let app else { return }

    ignoredApps.removeAll(where: { $0 == app })
    selection = nil
  }
}

// Also used by QuitSettingsTab.
struct IgnoredAppRow: View {
  let bundleIdentifier: String

  var body: some View {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
      Label {
        Text(NSWorkspace.shared.applicationName(url: url))
      } icon: {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
          .resizable()
          .frame(width: 18, height: 18)
      }
    } else {
      Label {
        Text(bundleIdentifier)
      } icon: {
        Image(systemName: "questionmark.app.dashed")
      }
    }
  }
}

#Preview {
  HistorySettingsTab()
    .environment(\.locale, .init(identifier: "en"))
}
