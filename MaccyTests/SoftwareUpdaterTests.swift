import Foundation
import Sparkle
import Testing
@testable import Maccy

// In-app updates (Maccy/SoftwareUpdater.swift): the feed and key the app ships with, and that
// tests never start the updater, so they stay offline.
@MainActor
struct SoftwareUpdaterTests {
  private func info(_ key: String) -> Any? {
    Bundle.main.object(forInfoDictionaryKey: key)
  }

  @Test("The feed is the appcast attached to the latest GitHub release, over HTTPS")
  func feedURL() throws {
    let feed = try #require(info("SUFeedURL") as? String)
    #expect(feed == "https://github.com/eddytwist/multipasta/releases/latest/download/appcast.xml")
  }

  @Test("Updates are verified with Multipasta's EdDSA key before they are unpacked")
  func publicKey() throws {
    let key = try #require(info("SUPublicEDKey") as? String)
    #expect(Data(base64Encoded: key)?.count == 32)
    #expect(info("SUVerifyUpdateBeforeExtraction") as? Bool == true)
  }

  @Test("Automatic checks are on by default, once a day, without Sparkle's permission prompt")
  func automaticChecks() {
    #expect(info("SUEnableAutomaticChecks") as? Bool == true)
    #expect(info("SUScheduledCheckInterval") as? Int == 86400)
  }

  @Test("Tests don't start the updater")
  func notStartedInTests() {
    #expect(AppDelegate.isTesting)
    #expect(!SoftwareUpdater.shared.isStarted)
  }

  @Test("A scheduled update never opens Sparkle's window by itself", arguments: [false, true])
  func noPopup(immediateFocus: Bool) {
    let reminders = GentleReminders()
    #expect(reminders.supportsGentleScheduledUpdateReminders)
    #expect(!reminders.standardUserDriverShouldHandleShowingScheduledUpdate(
      SUAppcastItem.empty(), andInImmediateFocus: immediateFocus
    ))
  }

  @Test("The waiting update clears once the user sees it or the session ends")
  func gentleRemindersClear() {
    let reminders = GentleReminders()
    var pending: [String?] = []
    reminders.onPendingChange = { pending.append($0) }
    reminders.standardUserDriverDidReceiveUserAttention(forUpdate: SUAppcastItem.empty())
    reminders.standardUserDriverWillFinishUpdateSession()
    #expect(pending == [nil, nil])
  }

  @Test("Sparkle is embedded in the app")
  func frameworkEmbedded() {
    let framework = Bundle.main.privateFrameworksURL?.appending(path: "Sparkle.framework")
    #expect(framework.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == true)
  }
}
