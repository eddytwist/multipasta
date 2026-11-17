import AudioToolbox
import Defaults
import Foundation
import UserNotifications
import os

// Multipasta: feedback sounds, played by the app itself instead of through macOS notifications.
// They are system sounds (AudioServices) that macOS treats as user interface sounds, so they
// follow "Play user interface sound effects", the alert volume and the sound effects output
// device in System Settings → Sound.

/// A feedback sound and the file it plays.
enum FeedbackSound: CaseIterable, Sendable {
  /// A copy was recorded in the history (⌘C, also a copy that was already there).
  case write
  /// An item was chosen from the history (and each step of a paste stack).
  case knock
  /// A line was copied to the list (Maccy/ListCopy).
  case writeDouble

  var resource: String {
    switch self {
    case .write: "Write"
    case .knock: "Knock"
    case .writeDouble: "WriteDouble"
    }
  }

  /// Settings → General → Sounds: list copy has its own toggle, everything else is a copy.
  var isOn: Bool {
    switch self {
    case .write, .knock: Defaults[.playCopySound]
    case .writeDouble: Defaults[.playListSound]
    }
  }
}

@MainActor
final class SoundPlayer {
  /// Everything the player needs from the outside, so that tests can record what plays.
  struct Environment {
    var isOn: @MainActor (FeedbackSound) -> Bool
    var output: @MainActor (FeedbackSound) -> Void

    static let live = Environment(
      isOn: { $0.isOn },
      output: { SoundPlayer.playSystemSound($0) }
    )
  }

  static let shared = SoundPlayer(environment: .live)
  static let logger = os.Logger(subsystem: "com.eddytwist.Multipasta", category: "sound")

  var environment: Environment
  /// Nothing plays until the settings are known (see `SoundSettingsMigration`), so a copy right
  /// after launch never plays under the wrong setting.
  var isReady = false

  init(environment: Environment) {
    self.environment = environment
  }

  func play(_ sound: FeedbackSound) {
    guard isReady, environment.isOn(sound) else { return }
    environment.output(sound)
  }

  // MARK: - System sounds

  private static var soundIDs: [FeedbackSound: SystemSoundID] = [:]

  private static func playSystemSound(_ sound: FeedbackSound) {
    guard let id = soundID(for: sound) else { return }
    AudioServicesPlaySystemSound(id)
  }

  private static func soundID(for sound: FeedbackSound) -> SystemSoundID? {
    if let id = soundIDs[sound] {
      return id
    }
    guard let url = Bundle.main.url(forResource: sound.resource, withExtension: "caf") else {
      logger.error("Missing sound file \(sound.resource, privacy: .public).caf")
      return nil
    }
    var id: SystemSoundID = 0
    let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
    guard status == kAudioServicesNoError else {
      logger.error("Cannot load sound \(sound.resource, privacy: .public): \(status)")
      return nil
    }
    soundIDs[sound] = id
    return id
  }
}

/// Up to 0.2.0 the sounds played only when Multipasta's notifications and their sound were
/// allowed in System Settings → Notifications. The first launch of a newer version carries that
/// choice over to the two toggles once; a new install starts with both on.
enum SoundSettingsMigration {
  enum NotificationSound: Equatable, Sendable {
    /// Notifications allowed with sound: the user heard the sounds.
    case on
    /// Notifications denied, or allowed without sound: the user did not hear them.
    case off
    /// The permission was never asked for: nothing to carry over.
    case notDetermined
  }

  /// Run at the very start of launch: `storeExisted` has to be read before anything creates the
  /// history store. Marks the player ready once the settings are known.
  @MainActor
  static func run(
    storeExisted: Bool,
    player: SoundPlayer = .shared,
    notificationSound: @escaping @Sendable () async -> NotificationSound = currentNotificationSound,
    clearDeliveredNotifications: @MainActor () -> Void = {
      UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    },
    timeout: Duration = .seconds(2)
  ) async {
    defer { player.isReady = true }
    guard !Defaults[.soundsMigrated] else { return }
    guard storeExisted else {
      Defaults[.soundsMigrated] = true
      return
    }

    // Older versions could leave banners with copied text in Notification Center; nothing posts
    // them any more. Doesn't ask for permission.
    clearDeliveredNotifications()

    let sound = await firstAnswer(of: notificationSound, within: timeout)
    if sound == .off {
      Defaults[.playCopySound] = false
      Defaults[.playListSound] = false
    }
    Defaults[.soundsMigrated] = true
    SoundPlayer.logger.info("Sound settings carried over from notifications: \(String(describing: sound), privacy: .public)")
  }

  /// Reads the notification settings without asking for permission.
  @Sendable
  static func currentNotificationSound() async -> NotificationSound {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    return notificationSound(status: settings.authorizationStatus, sound: settings.soundSetting)
  }

  /// What the old notification gate (authorized or provisional, with sound) meant for the user.
  nonisolated static func notificationSound(
    status: UNAuthorizationStatus,
    sound: UNNotificationSetting
  ) -> NotificationSound {
    switch status {
    case .notDetermined:
      return .notDetermined
    case .authorized, .provisional:
      return sound == .enabled ? .on : .off
    case .denied:
      return .off
    @unknown default:
      return .notDetermined
    }
  }

  /// A notification service that doesn't answer must not keep the sounds off for the session:
  /// after `timeout` it counts as "never asked" and the toggles stay on. Nothing waits for a late
  /// answer (the settings read ignores cancellation), it is just dropped.
  @MainActor
  private static func firstAnswer(
    of read: @escaping @Sendable () async -> NotificationSound,
    within timeout: Duration
  ) async -> NotificationSound {
    let once = ResumeOnce()
    return await withCheckedContinuation { continuation in
      once.continuation = continuation
      Task { @MainActor in
        once.resume(returning: await read())
      }
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        once.resume(returning: .notDetermined)
      }
    }
  }
}

/// Resumes a continuation with whichever answer comes first.
@MainActor
private final class ResumeOnce {
  var continuation: CheckedContinuation<SoundSettingsMigration.NotificationSound, Never>?

  func resume(returning value: SoundSettingsMigration.NotificationSound) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}
