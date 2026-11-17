import AppKit
import Foundation
import Observation
import Sparkle

// Multipasta: in-app updates through Sparkle. Once a day (when automatic checks are on) Sparkle
// reads the appcast attached to the latest GitHub release (SUFeedURL in Info.plist) and offers
// the new version. Updates are verified with Multipasta's EdDSA key (SUPublicEDKey), so they work
// without Apple notarization; the app keeps its code signature, so Accessibility stays granted.
@MainActor
@Observable
final class SoftwareUpdater {
  static let shared = SoftwareUpdater()

  /// Settings → General → About. Mirrors Sparkle's own setting, which it keeps in the app's
  /// standard defaults (SUEnableAutomaticChecks).
  var automaticallyChecksForUpdates = false {
    didSet {
      guard automaticallyChecksForUpdates != oldValue,
            controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
      controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  /// A scheduled check found this version. Nothing pops up: the menu bar icon gets a dot, the
  /// popup's footer shows "Update Available…" and Settings "Update to X…" until the user clicks.
  private(set) var pendingVersion: String?

  /// When Sparkle last checked, shown in Settings.
  private(set) var lastCheckDate: Date?

  /// Set once at launch; tests never start it.
  private(set) var isStarted = false

  @ObservationIgnored
  private let reminders: GentleReminders
  @ObservationIgnored
  private let controller: SPUStandardUpdaterController
  @ObservationIgnored
  private var observation: NSKeyValueObservation?

  private init() {
    let reminders = GentleReminders()
    self.reminders = reminders
    controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: reminders,
      userDriverDelegate: reminders
    )
    let updater = controller.updater
    automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    lastCheckDate = updater.lastUpdateCheckDate
    reminders.onPendingChange = { [weak self] version in self?.pendingVersion = version }
    reminders.onCycleFinished = { [weak self] in
      self?.lastCheckDate = self?.controller.updater.lastUpdateCheckDate
    }
    // The setting can change elsewhere too (Sparkle's own prompt). Read the current value when
    // the hop to the main actor lands, so two quick changes can't play an old one back.
    observation = updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in
        guard let self else { return }
        self.automaticallyChecksForUpdates = self.controller.updater.automaticallyChecksForUpdates
      }
    }
  }

  /// Called once at launch. Tests and Debug builds never start it, so they don't go online.
  func start() {
    guard !isStarted else { return }
    controller.startUpdater()
    isStarted = true
  }

  /// "Check for Updates…" and the footer's "Update Available…": Sparkle shows its progress and
  /// result windows, or brings forward the update it already found.
  func checkForUpdates() {
    NSApp.activate(ignoringOtherApps: true)
    controller.checkForUpdates(nil)
  }
}

/// Sparkle's gentle reminders, Multipasta style: nothing pops up by itself (Ed, 17.11.2026). A
/// scheduled check that finds an update only marks it: a dot on the menu bar icon, "Update
/// Available…" in the popup's footer and "Update to X…" in Settings. Sparkle's window opens when
/// the user clicks one of those or Check for Updates….
@MainActor
final class GentleReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate,
  @preconcurrency SPUUpdaterDelegate {
  var onPendingChange: (String?) -> Void = { _ in }
  var onCycleFinished: () -> Void = {}

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    if !state.userInitiated {
      onPendingChange(update.displayVersionString)
    }
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    onPendingChange(nil)
  }

  func standardUserDriverWillFinishUpdateSession() {
    onPendingChange(nil)
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    onCycleFinished()
  }
}
