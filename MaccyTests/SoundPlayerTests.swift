import AppKit
import Defaults
import Testing
import UserNotifications
@testable import Maccy

extension SharedStateTests {
  // Which event plays which sound under the two toggles, and how the toggles are seeded from the
  // notification settings of older versions. The player records instead of playing.
  @MainActor
  final class SoundPlayerTests {
    let savedCopySound = Defaults[.playCopySound]
    let savedListSound = Defaults[.playListSound]
    let savedMigrated = Defaults[.soundsMigrated]
    let savedEnabledTypes = Defaults[.enabledPasteboardTypes]
    let savedIgnoreEvents = Defaults[.ignoreEvents]
    let savedClearSystemClipboard = Defaults[.clearSystemClipboard]

    /// What the shared player "played". The recorder stays installed after the suite: deinit
    /// doesn't run on the main actor, and tests don't play real sounds anyway.
    final class Recorder {
      var played: [FeedbackSound] = []
    }
    let recorder = Recorder()
    var played: [FeedbackSound] {
      get { recorder.played }
      set { recorder.played = newValue }
    }

    init() {
      History.shared.clearAll()
      Clipboard.shared.clearHooks()
      Defaults[.playCopySound] = true
      Defaults[.playListSound] = true
      Defaults[.ignoreEvents] = false
      Defaults[.clearSystemClipboard] = false
      SoundPlayer.shared.isReady = true
      SoundPlayer.shared.environment = SoundPlayer.Environment(
        isOn: { $0.isOn },
        output: { [recorder] in recorder.played.append($0) }
      )
    }

    deinit {
      Defaults[.playCopySound] = savedCopySound
      Defaults[.playListSound] = savedListSound
      Defaults[.soundsMigrated] = savedMigrated
      Defaults[.enabledPasteboardTypes] = savedEnabledTypes
      Defaults[.ignoreEvents] = savedIgnoreEvents
      Defaults[.clearSystemClipboard] = savedClearSystemClipboard
    }

    // MARK: - Toggles

    @Test("Each sound follows its toggle")
    func toggles() {
      let player = SoundPlayer.shared
      FeedbackSound.allCases.forEach(player.play)
      #expect(played == [.write, .knock, .writeDouble])

      played = []
      Defaults[.playCopySound] = false
      FeedbackSound.allCases.forEach(player.play)
      #expect(played == [.writeDouble])

      played = []
      Defaults[.playCopySound] = true
      Defaults[.playListSound] = false
      FeedbackSound.allCases.forEach(player.play)
      #expect(played == [.write, .knock])
    }

    @Test("Nothing plays until the settings are known")
    func notReady() {
      SoundPlayer.shared.isReady = false
      defer { SoundPlayer.shared.isReady = true }
      SoundPlayer.shared.play(.write)
      #expect(played.isEmpty)
    }

    @Test("Every sound file is in the app")
    func filesExist() {
      for sound in FeedbackSound.allCases {
        #expect(Bundle.main.url(forResource: sound.resource, withExtension: "caf") != nil, "\(sound.resource)")
      }
    }

    // MARK: - History

    @Test("A new copy and a copy already in history both play Write")
    func copyAndDuplicate() async {
      History.shared.add(item("milk"))
      History.shared.add(item("bread"))
      History.shared.add(item("milk"))
      await settle()
      #expect(played == [.write, .write, .write])
      #expect(History.shared.items.count == 2)
    }

    @Test("A copy Multipasta made itself, or a list's item, plays nothing from the history")
    func ownCopiesSilent() async {
      History.shared.add(item("milk", fromMaccy: true))
      History.shared.add(item("bread"), notify: false)
      await settle()
      #expect(played.isEmpty)
    }

    @Test("A duplicate of a copy Multipasta made itself stays silent")
    func ownDuplicateSilent() async {
      History.shared.add(item("milk"))
      await settle()
      played = []
      History.shared.add(item("milk", fromMaccy: true))
      await settle()
      #expect(played.isEmpty)
    }

    @Test("With the copy sound off a copy is silent")
    func copySoundOff() async {
      Defaults[.playCopySound] = false
      History.shared.add(item("milk"))
      await settle()
      #expect(played.isEmpty)
    }

    // MARK: - Clipboard

    @Test("Choosing an item from history plays Knock once, without Write for its re-record")
    func chooseFromHistory() async {
      Defaults[.enabledPasteboardTypes] = [.string]
      Clipboard.shared.onNewCopy { History.shared.add($0) }
      defer { Clipboard.shared.clearHooks() }
      let chosen = History.shared.add(item("milk"))
      await settle()
      played = []

      Clipboard.shared.copy(chosen.item)
      await settle()
      #expect(played == [.knock])
    }

    @Test("Each paste-stack step plays Knock, never Write")
    func pasteStack() async {
      Defaults[.enabledPasteboardTypes] = [.string]
      Clipboard.shared.onNewCopy { History.shared.add($0) }
      defer { Clipboard.shared.clearHooks() }
      let items = ["one", "two", "three"].map { History.shared.add(item("\($0) \(UUID().uuidString)")) }
      await settle()
      played = []

      History.shared.pasteStack = PasteStack(items: items, modifierFlags: [])
      History.shared.handlePasteStack()
      await settle()
      History.shared.handlePasteStack()
      await settle()
      #expect(played == [.knock, .knock])
      History.shared.pasteStack = nil
    }

    @Test("Copying the search query records a copy: Write once")
    func copyInMaccy() async {
      Defaults[.enabledPasteboardTypes] = [.string]
      Clipboard.shared.onNewCopy { History.shared.add($0) }
      defer { Clipboard.shared.clearHooks() }
      Clipboard.shared.copyInMaccy("query \(UUID().uuidString)")
      await settle()
      #expect(played == [.write])
    }

    @Test("A copy while history is paused is not recorded and plays nothing")
    func pausedSilent() async {
      Defaults[.enabledPasteboardTypes] = [.string]
      Defaults[.ignoreEvents] = true
      Clipboard.shared.onNewCopy { History.shared.add($0) }
      defer { Clipboard.shared.clearHooks() }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString("paused \(UUID().uuidString)", forType: .string)
      Clipboard.shared.checkForChangesInPasteboard()
      await settle()
      #expect(played.isEmpty)
    }

    // MARK: - Migration from notifications

    @Test("A new install keeps both sounds on and doesn't ask for notification settings")
    func newInstall() async {
      Defaults[.soundsMigrated] = false
      let player = SoundPlayer(environment: SoundPlayer.shared.environment)
      await SoundSettingsMigration.run(
        storeExisted: false,
        player: player,
        notificationSound: {
          Issue.record("Notification settings read for a new install")
          return .off
        },
        clearDeliveredNotifications: { Issue.record("Notifications cleared for a new install") }
      )
      #expect(Defaults[.playCopySound] && Defaults[.playListSound])
      #expect(Defaults[.soundsMigrated])
      #expect(player.isReady)
    }

    @Test(
      "An update carries the notification sound over once",
      arguments: [
        (SoundSettingsMigration.NotificationSound.on, true),
        (.notDetermined, true),
        (.off, false)
      ]
    )
    func update(sound: SoundSettingsMigration.NotificationSound, expected: Bool) async {
      Defaults[.soundsMigrated] = false
      let player = SoundPlayer(environment: SoundPlayer.shared.environment)
      #expect(!player.isReady)
      var cleared = 0
      await SoundSettingsMigration.run(
        storeExisted: true, player: player, notificationSound: { sound }, clearDeliveredNotifications: { cleared += 1 }
      )
      #expect(cleared == 1)
      #expect(Defaults[.playCopySound] == expected)
      #expect(Defaults[.playListSound] == expected)
      #expect(Defaults[.soundsMigrated])
      #expect(player.isReady)
    }

    @Test("Once carried over, the toggles are left as the user set them")
    func alreadyMigrated() async {
      Defaults[.soundsMigrated] = true
      Defaults[.playCopySound] = true
      Defaults[.playListSound] = false
      let player = SoundPlayer(environment: SoundPlayer.shared.environment)
      await SoundSettingsMigration.run(
        storeExisted: true,
        player: player,
        notificationSound: {
          Issue.record("Notification settings read again")
          return .off
        },
        clearDeliveredNotifications: { Issue.record("Notifications cleared again") }
      )
      #expect(Defaults[.playCopySound])
      #expect(!Defaults[.playListSound])
      #expect(player.isReady)
    }

    @Test(
      "The old notification gate maps to the toggles",
      arguments: [
        (UNAuthorizationStatus.authorized, UNNotificationSetting.enabled, SoundSettingsMigration.NotificationSound.on),
        (.authorized, .disabled, .off),
        (.provisional, .enabled, .on),
        (.provisional, .disabled, .off),
        (.denied, .enabled, .off),
        (.denied, .disabled, .off),
        (.notDetermined, .notSupported, .notDetermined)
      ]
    )
    func notificationMapping(
      status: UNAuthorizationStatus,
      sound: UNNotificationSetting,
      expected: SoundSettingsMigration.NotificationSound
    ) {
      #expect(SoundSettingsMigration.notificationSound(status: status, sound: sound) == expected)
    }

    @Test("A notification service that doesn't answer leaves the sounds on")
    func notificationTimeout() async {
      Defaults[.soundsMigrated] = false
      Defaults[.playCopySound] = true
      let player = SoundPlayer(environment: SoundPlayer.shared.environment)
      let start = ContinuousClock.now
      // Like the real read, the stub ignores cancellation.
      await SoundSettingsMigration.run(
        storeExisted: true,
        player: player,
        notificationSound: {
          await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { continuation.resume(returning: .off) }
          }
        },
        clearDeliveredNotifications: {},
        timeout: .milliseconds(300)
      )
      #expect(ContinuousClock.now - start < .seconds(2))
      #expect(Defaults[.playCopySound])
      #expect(player.isReady)
    }

    // MARK: - Helpers

    private func item(_ text: String, fromMaccy: Bool = false) -> HistoryItem {
      var contents = [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
      ]
      if fromMaccy {
        contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.fromMaccy.rawValue, value: Data()))
      }
      let item = HistoryItem(contents: contents)
      item.title = item.generateTitle()
      return item
    }

    /// History and the clipboard play from a task: let it run.
    private func settle() async {
      for _ in 0..<20 {
        await Task.yield()
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }
}
