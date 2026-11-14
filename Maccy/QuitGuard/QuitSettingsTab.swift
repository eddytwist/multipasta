import SwiftUI
import Defaults

// Multipasta: the "Quit" tab of the settings window — the ⌘Q guard.
// The app list mirrors IgnoredAppsSection in HistorySettingsTab.swift.
struct QuitSettingsTab: View {
  @Default(.quitGuardApps) private var apps

  @State private var status: QuitGuardSystemStatus
  @State private var isAdding = false
  @State private var selection: String?
  @State private var isWindowVisible = false

  private let isLive: Bool

  /// Pass `status` to show a fixed system state (snapshots, previews) instead of the live one.
  init(status: QuitGuardSystemStatus? = nil) {
    _status = State(initialValue: status ?? .current)
    isLive = status == nil
  }

  var body: some View {
    Form {
      Section {
        LabeledContent {
          if status.isAccessibilityTrusted {
            Label {
              Text("QuitAccessibilityGranted", tableName: "MultipastaSettings")
            } icon: {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
            .labelStyle(.titleAndIcon)
          } else {
            Button {
              Accessibility.openSystemSettings()
            } label: {
              Text("QuitOpenSystemSettings", tableName: "MultipastaSettings")
            }
          }
        } label: {
          Text("QuitAccessibility", tableName: "MultipastaSettings")
          Text(
            status.isAccessibilityTrusted ? "QuitAccessibilityCaption" : "QuitAccessibilityCaptionMissing",
            tableName: "MultipastaSettings"
          )
        }
      }

      appsSection
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .frame(width: SettingsLayout.width)
    .fixedSize(horizontal: false, vertical: true)
    .background {
      if isLive {
        WindowVisibilityReader(isVisible: $isWindowVisible)
      }
    }
    // Accessibility and Secure Keyboard Entry change outside the app. There is no notification
    // for Secure Keyboard Entry, so check once a second, and only while the window is on screen.
    .task(id: isWindowVisible) {
      guard isLive, isWindowVisible else { return }
      while !Task.isCancelled {
        refreshStatus()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onReceive(
      DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))
    ) { _ in
      guard isLive else { return }
      // The new Accessibility state is readable a moment after the notification.
      Task {
        try? await Task.sleep(for: .milliseconds(500))
        refreshStatus()
      }
    }
  }

  private var appsSection: some View {
    Section {
      List(selection: $selection) {
        ForEach(apps, id: \.self) { app in
          IgnoredAppRow(bundleIdentifier: app)
            .tag(app)
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: false))
      .overlay {
        if apps.isEmpty {
          Text("QuitGuardAppsEmpty", tableName: "MultipastaSettings")
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
        if case .success(let appUrl) = result,
           let bundleIdentifier = Bundle(path: appUrl.path)?.bundleIdentifier,
           !QuitGuard.unguardableBundleIdentifiers.contains(bundleIdentifier),
           !apps.contains(bundleIdentifier) {
          apps.append(bundleIdentifier)
        }
      }
    } header: {
      VStack(alignment: .leading, spacing: 2) {
        Text("QuitGuardApps", tableName: "MultipastaSettings")
        Text("QuitGuardCaption", tableName: "MultipastaSettings")
          .font(.footnote)
          .fontWeight(.regular)
          .foregroundStyle(.secondary)
      }
    } footer: {
      if status.isSecureInputEnabled {
        Label {
          if let appName = status.secureInputAppName {
            Text("QuitSecureInputApp \(appName)", tableName: "MultipastaSettings")
          } else {
            Text("QuitSecureInput", tableName: "MultipastaSettings")
          }
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.yellow)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func refreshStatus() {
    let current = QuitGuardSystemStatus.current
    if current != status {
      status = current
    }
  }

  private func remove(_ app: String?) {
    guard let app else { return }

    apps.removeAll(where: { $0 == app })
    selection = nil
  }
}

/// Reports whether the window that hosts the view is open and not fully covered.
private struct WindowVisibilityReader: NSViewRepresentable {
  @Binding var isVisible: Bool

  func makeNSView(context: Context) -> ReaderView {
    ReaderView { visible in
      if isVisible != visible {
        isVisible = visible
      }
    }
  }

  func updateNSView(_ view: ReaderView, context: Context) {}

  final class ReaderView: NSView {
    private let onChange: (Bool) -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onChange: @escaping (Bool) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      tokens.forEach(NotificationCenter.default.removeObserver)
      tokens = []
      guard let window else {
        report(false)
        return
      }

      let center = NotificationCenter.default
      for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
        tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.reportWindowState() }
        })
      }
      let closeName = NSWindow.willCloseNotification
      tokens.append(center.addObserver(forName: closeName, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.report(false) }
      })
      reportWindowState()
    }

    private func reportWindowState() {
      guard let window else { return report(false) }
      report(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func report(_ visible: Bool) {
      // Not during a view update.
      DispatchQueue.main.async { [weak self] in self?.onChange(visible) }
    }
  }
}

#Preview {
  QuitSettingsTab(
    status: QuitGuardSystemStatus(
      isAccessibilityTrusted: true,
      isSecureInputEnabled: true,
      secureInputAppName: "Terminal"
    )
  )
  .environment(\.locale, .init(identifier: "en"))
}
