// swiftlint:disable file_length
import AppKit
import SwiftUI
import Defaults
import KeyboardShortcuts

// Multipasta: everything Maccy exposes in its Storage, Appearance, Ignore and Advanced
// panes (and the extra shortcuts from its General pane) that is not on the General or
// History tab. Opened from the "Advanced…" button on the History tab.
// The Defaults keys and their defaults are Maccy's; only the layout is new.
struct AdvancedSettingsSheet: View { // swiftlint:disable:this type_body_length
  @Environment(\.dismiss) private var dismiss

  // Saving
  @Default(.sortBy) private var sortBy
  @Default(.clipboardCheckInterval) private var clipboardCheckInterval
  @State private var storage = StorageSettingsPane.ViewModel()

  // Ignore
  @Default(.ignoredPasteboardTypes) private var ignoredPasteboardTypes
  @Default(.ignoreRegexp) private var ignoredRegexps

  // Popup
  @Default(.popupPosition) private var popupAt
  @Default(.popupScreen) private var popupScreen
  @Default(.windowPosition) private var windowPosition
  @Default(.pinTo) private var pinTo
  @Default(.searchMode) private var searchMode
  @Default(.highlightMatch) private var highlightMatch
  @Default(.imageMaxHeight) private var imageHeight
  @Default(.openPreviewAutomatically) private var openPreviewAutomatically
  @Default(.previewDelay) private var previewDelay

  // Appearance
  @Default(.menuIcon) private var menuIcon
  @Default(.showInStatusBar) private var showInStatusBar
  @Default(.showSearch) private var showSearch
  @Default(.searchVisibility) private var searchVisibility
  @Default(.showFooter) private var showFooter

  // Import from Maccy
  @State private var maccyStoreExists = MaccyImporter.storeExists()
  @State private var isImportingFromMaccy = false

  @State private var screens = NSScreen.screens
  // Read so that the modifiers description below refreshes when either changes.
  @Default(.pasteByDefault) private var pasteByDefault
  @Default(.removeFormattingByDefault) private var removeFormattingByDefault

  private let checkIntervalFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0.1
    formatter.maximum = 60
    formatter.maximumFractionDigits = 2
    return formatter
  }()

  private let imageHeightFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 200
    return formatter
  }()

  private let previewDelayFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 200
    formatter.maximum = 100_000
    return formatter
  }()

  var body: some View {
    VStack(spacing: 0) {
      Form {
        savingSection
        clearingSection
        importSection
        pasteboardTypesSection
        regexpsSection
        popupSection
        pastingSection
        ListCopySettingsSection()
        appearanceSection
        shortcutsSection
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Done", tableName: "MultipastaSettings")
            .frame(minWidth: 60)
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
    // No wider than the settings window; resizable in height up to what fits on screen.
    .frame(width: SettingsLayout.width)
    .frame(minHeight: 360, idealHeight: Self.idealHeight, maxHeight: Self.maxHeight)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      screens = NSScreen.screens
    }
  }

  // MARK: - Sections

  private var savingSection: some View {
    Section {
      Toggle(isOn: $storage.saveText) {
        Text("Text", tableName: "MultipastaSettings")
      }
      Toggle(isOn: $storage.saveFiles) {
        Text("Files", tableName: "MultipastaSettings")
      }

      Picker(selection: $sortBy) {
        ForEach(Sorter.By.allCases) { mode in
          Text(mode.description)
        }
      } label: {
        Text("SortBy", tableName: "MultipastaSettings")
      }
      .help(Text("SortByTooltip", tableName: "StorageSettings"))

      LabeledContent {
        HStack(spacing: 6) {
          TextField("", value: $clipboardCheckInterval, formatter: checkIntervalFormatter)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            .accessibilityLabel(Text("CheckInterval", tableName: "MultipastaSettings"))
          Stepper("", value: $clipboardCheckInterval, in: 0.1...60, step: 0.1)
            .labelsHidden()
            .accessibilityLabel(Text("CheckInterval", tableName: "MultipastaSettings"))
          Text("CheckIntervalUnit", tableName: "MultipastaSettings")
            .foregroundStyle(.secondary)
        }
      } label: {
        Text("CheckInterval", tableName: "MultipastaSettings")
        Text("CheckIntervalCaption", tableName: "MultipastaSettings")
      }

      Defaults.Toggle(key: .ignoreEvents) {
        Text("PauseHistory", tableName: "MultipastaSettings")
        Text("TurnOffViaMenuIconDescription", tableName: "AdvancedSettings")
      }
      .help(Text("TurnOffDescription", tableName: "AdvancedSettings"))
    } header: {
      Text("Saving", tableName: "MultipastaSettings")
    }
  }

  private var clearingSection: some View {
    Section {
      Defaults.Toggle(key: .clearOnQuit) {
        Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")
      }
      .help(Text("ClearHistoryOnQuitTooltip", tableName: "AdvancedSettings"))

      Defaults.Toggle(key: .clearSystemClipboard) {
        Text("ClearSystemClipboard", tableName: "AdvancedSettings")
      }
      .help(Text("ClearSystemClipboardTooltip", tableName: "AdvancedSettings"))
    } header: {
      Text("Clearing", tableName: "MultipastaSettings")
    }
  }

  // Multipasta: manual import of upstream Maccy's history (see MaccyImporter.swift).
  private var importSection: some View {
    Section {
      LabeledContent {
        HStack(spacing: 8) {
          if isImportingFromMaccy {
            ProgressView()
              .controlSize(.small)
          }
          Button {
            isImportingFromMaccy = true
            Task {
              await MaccyImporter.importAndReport()
              isImportingFromMaccy = false
            }
          } label: {
            Text("MaccyImportButton", tableName: "MultipastaSettings")
          }
          .disabled(!maccyStoreExists || isImportingFromMaccy)
        }
      } label: {
        Text("MaccyImportLabel", tableName: "MultipastaSettings")
        if maccyStoreExists {
          Text("MaccyImportCaption", tableName: "MultipastaSettings")
        } else {
          Text("MaccyImportNotFound", tableName: "MultipastaSettings")
        }
      }
      .onAppear {
        maccyStoreExists = MaccyImporter.storeExists()
      }
    } header: {
      Text("MaccyImportSection", tableName: "MultipastaSettings")
    }
  }

  // Mirrors IgnorePasteboardTypesSettingsView.swift (same key, placeholder and Reset).
  private var pasteboardTypesSection: some View {
    Section {
      StringListEditor(
        values: Binding(
          get: { ignoredPasteboardTypes.sorted() },
          set: { ignoredPasteboardTypes = Set($0) }
        ),
        newValue: "xxx.yyy.zzz",
        onReset: { Defaults.reset(.ignoredPasteboardTypes) }
      )
    } header: {
      Text("PasteboardTypes", tableName: "MultipastaSettings")
    } footer: {
      SectionFooter(Text("IgnoredPasteboardTypesDescription", tableName: "IgnoreSettings"))
    }
  }

  // Mirrors IgnoreRegexpsSettingsView.swift (same key and placeholder).
  private var regexpsSection: some View {
    Section {
      StringListEditor(values: $ignoredRegexps, newValue: "^[a-zA-Z0-9]{50}$")
    } header: {
      Text("Regexps", tableName: "MultipastaSettings")
    } footer: {
      SectionFooter(Text("IgnoredRegexpsDescription", tableName: "IgnoreSettings"))
    }
  }

  private var popupSection: some View {
    Section {
      LabeledContent {
        HStack(spacing: 4) {
          if popupAt == .lastPosition {
            Button {
              _windowPosition.reset()
            } label: {
              Image(systemName: "arrow.uturn.backward.circle.fill")
            }
            .buttonStyle(.borderless)
            .help(Text("ResetPosition", tableName: "MultipastaSettings"))
            .accessibilityLabel(Text("ResetPosition", tableName: "MultipastaSettings"))
            .disabled(windowPosition == _windowPosition.defaultValue)
          }

          Picker(selection: $popupAt) {
            ForEach(PopupPosition.allCases) { position in
              if position == .center || position == .lastPosition, screens.count > 1 {
                screenPicker(for: position)
              } else {
                Text(position.description)
              }
            }
          } label: {
            Text("PopupAt", tableName: "MultipastaSettings")
          }
          .labelsHidden()
          .fixedSize()
        }
      } label: {
        Text("PopupAt", tableName: "MultipastaSettings")
      }
      .help(Text("PopupAtTooltip", tableName: "AppearanceSettings"))

      Picker(selection: $pinTo) {
        ForEach(PinsPosition.allCases) { position in
          Text(position.description)
        }
      } label: {
        Text("PinTo", tableName: "MultipastaSettings")
      }
      .help(Text("PinToTooltip", tableName: "AppearanceSettings"))

      Picker(selection: $searchMode) {
        ForEach(Search.Mode.allCases) { mode in
          Text(mode.description)
        }
      } label: {
        Text("SearchMode", tableName: "MultipastaSettings")
      }

      Picker(selection: $highlightMatch) {
        ForEach(HighlightMatch.allCases) { match in
          Text(match.description)
        }
      } label: {
        Text("HighlightMatches", tableName: "MultipastaSettings")
      }
      .help(Text("HighlightMatchesTooltip", tableName: "AppearanceSettings"))

      numberRow(
        value: $imageHeight,
        range: 1...200,
        formatter: imageHeightFormatter,
        label: "ImageHeight",
        unit: nil
      )
      .help(Text("ImageHeightTooltip", tableName: "AppearanceSettings"))

      Defaults.Toggle(key: .openPreviewAutomatically) {
        Text("OpenPreviewAutomatically", tableName: "MultipastaSettings")
        Text("OpenPreviewAutomaticallyCaption", tableName: "MultipastaSettings")
      }

      numberRow(
        value: $previewDelay,
        range: 200...100_000,
        formatter: previewDelayFormatter,
        label: "PreviewDelay",
        unit: "PreviewDelayUnit"
      )
      .disabled(!openPreviewAutomatically)
      .help(Text("PreviewDelayTooltip", tableName: "AppearanceSettings"))
    } header: {
      Text("Popup", tableName: "MultipastaSettings")
    }
  }

  private var pastingSection: some View {
    Section {
      Defaults.Toggle(key: .removeFormattingByDefault) {
        Text("PasteWithoutFormatting", tableName: "MultipastaSettings")
        Text(verbatim: modifiersDescription(pasteByDefault, removeFormattingByDefault))
      }
    } header: {
      Text("Pasting", tableName: "MultipastaSettings")
    }
  }

  private var appearanceSection: some View {
    Section {
      LabeledContent {
        HStack(spacing: 8) {
          Picker(selection: $menuIcon) {
            ForEach(MenuIcon.allCases) { icon in
              Image(nsImage: icon.image)
            }
          } label: {
            Text("ShowMenuIcon", tableName: "MultipastaSettings")
          }
          .labelsHidden()
          .fixedSize()
          .disabled(!showInStatusBar)

          Toggle(isOn: $showInStatusBar) {
            Text("ShowMenuIcon", tableName: "MultipastaSettings")
          }
          .labelsHidden()
          .toggleStyle(.switch)
        }
      } label: {
        Text("ShowMenuIcon", tableName: "MultipastaSettings")
      }

      Defaults.Toggle(key: .showRecentCopyInMenuBar) {
        Text("ShowRecentCopy", tableName: "MultipastaSettings")
      }

      LabeledContent {
        HStack(spacing: 8) {
          Picker(selection: $searchVisibility) {
            ForEach(SearchVisibility.allCases) { type in
              Text(type.description)
            }
          } label: {
            Text("ShowSearchField", tableName: "MultipastaSettings")
          }
          .labelsHidden()
          .fixedSize()
          .disabled(!showSearch)

          Toggle(isOn: $showSearch) {
            Text("ShowSearchField", tableName: "MultipastaSettings")
          }
          .labelsHidden()
          .toggleStyle(.switch)
        }
      } label: {
        Text("ShowSearchField", tableName: "MultipastaSettings")
      }

      Defaults.Toggle(key: .showTitle) {
        Text("ShowTitle", tableName: "MultipastaSettings")
      }

      Defaults.Toggle(key: .showApplicationIcons) {
        Text("ShowApplicationIcons", tableName: "MultipastaSettings")
      }

      Defaults.Toggle(key: .showHexColorSwatch) {
        Text("ShowHexColorSwatch", tableName: "MultipastaSettings")
      }
      .help(Text("ShowHexColorSwatchTooltip", tableName: "AppearanceSettings"))

      Defaults.Toggle(key: .showSpecialSymbols) {
        Text("ShowSpecialSymbols", tableName: "MultipastaSettings")
      }
      .help(Text("ShowSpecialSymbolsTooltip", tableName: "AppearanceSettings"))

      Defaults.Toggle(key: .showFooter) {
        Text("ShowFooter", tableName: "MultipastaSettings")
        if !showFooter {
          Text("ShowFooterCaption", tableName: "MultipastaSettings")
        }
      }
    } header: {
      Text("Appearance", tableName: "MultipastaSettings")
    }
  }

  private var shortcutsSection: some View {
    Section {
      KeyboardShortcuts.Recorder(for: .pin) {
        Text("PinShortcut", tableName: "MultipastaSettings")
      }
      .help(Text("PinTooltip", tableName: "GeneralSettings"))

      KeyboardShortcuts.Recorder(for: .delete) {
        Text("DeleteShortcut", tableName: "MultipastaSettings")
      }
      .help(Text("DeleteTooltip", tableName: "GeneralSettings"))

      KeyboardShortcuts.Recorder(for: .togglePreview) {
        Text("PreviewShortcut", tableName: "MultipastaSettings")
      }
      .help(Text("ShowPreviewTooltip", tableName: "GeneralSettings"))
    } header: {
      Text("Shortcuts", tableName: "MultipastaSettings")
    }
  }

  // MARK: - Helpers

  // The sheet's content is long, so it scrolls. Keep it inside the visible screen area,
  // leaving room for the settings window's title bar and toolbar above it.
  private static var maxHeight: CGFloat {
    let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
    return max(360, visibleHeight - 120)
  }

  private static var idealHeight: CGFloat {
    min(620, maxHeight)
  }

  // Mirrors GeneralSettingsPane.swift (refreshModifiers). The arguments are unused on purpose:
  // they make the dependency on both keys explicit.
  private func modifiersDescription(_ pasteByDefault: Bool, _ removeFormattingByDefault: Bool) -> String {
    String(
      format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
      HistoryItemAction.copy.modifierFlags.description,
      HistoryItemAction.paste.modifierFlags.description,
      HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
    )
  }

  private func numberRow(
    value: Binding<Int>,
    range: ClosedRange<Int>,
    formatter: NumberFormatter,
    label: LocalizedStringKey,
    unit: LocalizedStringKey?
  ) -> some View {
    LabeledContent {
      HStack(spacing: 6) {
        TextField("", value: value, formatter: formatter)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 64)
          .accessibilityLabel(Text(label, tableName: "MultipastaSettings"))
        Stepper("", value: value, in: range)
          .labelsHidden()
          .accessibilityLabel(Text(label, tableName: "MultipastaSettings"))
        if let unit {
          Text(unit, tableName: "MultipastaSettings")
            .foregroundStyle(.secondary)
        }
      }
    } label: {
      Text(label, tableName: "MultipastaSettings")
    }
  }

  // Mirrors AppearanceSettingsPane.swift (screenPicker(for:) and labelForScreen(index:)).
  @ViewBuilder
  private func screenPicker(for position: PopupPosition) -> some View {
    let screenBinding: Binding<Int> = Binding {
      return popupScreen
    } set: {
      popupScreen = $0
      popupAt = position
    }

    Picker(selection: screenBinding) {
      Text(labelForScreen(index: 0))
        .tag(0)

      ForEach(screens.indices, id: \.self) { index in
        Text(labelForScreen(index: index + 1))
          .tag(index + 1)
      }
    } label: {
      if popupAt == position {
        Text("\(position.description) (\(labelForScreen(index: popupScreen)))")
      } else {
        Text(position.description)
      }
    }
  }

  private func labelForScreen(index screenIndex: Int) -> String {
    switch screenIndex {
    case 0:
      return String(localized: "ActiveScreen", table: "AppearanceSettings")
    case _:
      guard screens.indices.contains(screenIndex - 1) else {
        return String(localized: "ActiveScreen", table: "AppearanceSettings")
      }
      return screens[screenIndex - 1].localizedName
    }
  }
}

// A small editable list of strings with +/− buttons, styled like the other tables
// in the settings window. Mirrors the list logic of IgnorePasteboardTypesSettingsView.swift
// and IgnoreRegexpsSettingsView.swift (edit on submit, + inserts a focused placeholder).
struct StringListEditor: View {
  @Binding var values: [String]
  // Inserted by the + button and focused for editing, as in Maccy.
  let newValue: String
  var onReset: (() -> Void)?

  @FocusState private var focus: String?
  @State private var edit = ""
  @State private var selection: String?

  var body: some View {
    List(selection: $selection) {
      ForEach(values, id: \.self) { value in
        TextField("", text: Binding(
          get: { value },
          set: {
            guard !$0.isEmpty, value != $0 else { return }
            edit = $0
          }
        ))
        .labelsHidden()
        .textFieldStyle(.plain)
        .onSubmit {
          replace(value, with: edit)
        }
        .focused($focus, equals: value)
        .tag(value)
      }
    }
    .listStyle(.bordered(alternatesRowBackgrounds: false))
    .overlay {
      if values.isEmpty {
        Text("ListEmpty", tableName: "MultipastaSettings")
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: 128)
    .onDeleteCommand {
      remove(selection)
    }

    HStack(spacing: 0) {
      Button {
        if !values.contains(newValue) {
          values.append(newValue)
        }
        focus = newValue
      } label: {
        Image(systemName: "plus")
          .frame(width: 20, height: 16)
      }
      .accessibilityLabel(Text("AddItem", tableName: "MultipastaSettings"))
      .help(Text("AddItem", tableName: "MultipastaSettings"))

      Button {
        remove(selection)
      } label: {
        Image(systemName: "minus")
          .frame(width: 20, height: 16)
      }
      .disabled(selection == nil)
      .accessibilityLabel(Text("RemoveItem", tableName: "MultipastaSettings"))
      .help(Text("RemoveItem", tableName: "MultipastaSettings"))

      Spacer()

      if let onReset {
        Button {
          onReset()
        } label: {
          Text("IgnoredPasteboardTypesReset", tableName: "IgnoreSettings")
        }
        .buttonStyle(.link)
      }
    }
    .buttonStyle(.borderless)
  }

  private func replace(_ value: String, with newValue: String) {
    guard !newValue.isEmpty, newValue != value else { return }

    if let index = values.firstIndex(of: value), !values.contains(newValue) {
      values[index] = newValue
    } else {
      values.removeAll(where: { $0 == value })
    }
    edit = ""
  }

  private func remove(_ value: String?) {
    guard let value else { return }

    values.removeAll(where: { $0 == value })
    selection = nil
  }
}

// Grey explanatory text under a grouped form section.
struct SectionFooter: View {
  let text: Text

  init(_ text: Text) {
    self.text = text
  }

  var body: some View {
    text
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview {
  AdvancedSettingsSheet()
    .environment(\.locale, .init(identifier: "en"))
}
