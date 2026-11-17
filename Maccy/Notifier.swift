import Foundation

// Multipasta: no notifications any more, only the feedback sound (Maccy/Sounds/SoundPlayer.swift).
// The type and its call sites stay as in Maccy to keep upstream merges simple.
class Notifier {
  /// Plays `sound` if its toggle in Settings → General → Sounds is on. `body` is not shown.
  @MainActor
  static func notify(body: String?, sound: FeedbackSound?) {
    guard let sound else { return }
    SoundPlayer.shared.play(sound)
  }
}
