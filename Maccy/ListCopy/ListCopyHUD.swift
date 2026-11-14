import AppKit
import SwiftUI

// Multipasta: the short message after the add-to-list shortcut ("Added to list · 3").
// Same panel and look as the ⌘Q guard HUD (QuitGuardHUD.swift); it hides by itself.

enum ListCopyHUDMessage: Equatable {
  case added(count: Int)
  case newList
  case nothingToAdd
  case onlyText
  /// Concealed or transient content (password managers): never added.
  case hiddenContent
  /// "Ignore new copies" is on.
  case paused
  /// An ignored app, pasteboard type or regular expression.
  case ignored

  var symbolName: String {
    switch self {
    case .added, .newList:
      return "list.bullet"
    case .nothingToAdd:
      return "text.cursor"
    case .onlyText, .ignored:
      return "exclamationmark.circle"
    case .hiddenContent:
      return "eye.slash"
    case .paused:
      return "pause.circle"
    }
  }

  /// The key in the MultipastaSettings table and the count it takes, if any.
  fileprivate var localization: (key: String, count: Int?) {
    switch self {
    case .added(let count):
      return ("ListHUDAdded %lld", count)
    case .newList:
      return ("ListHUDNewList %lld", 1)
    case .nothingToAdd:
      return ("ListHUDNothingToAdd", nil)
    case .onlyText:
      return ("ListHUDOnlyText", nil)
    case .hiddenContent:
      return ("ListHUDHidden", nil)
    case .paused:
      return ("ListHUDPaused", nil)
    case .ignored:
      return ("ListHUDIgnored", nil)
    }
  }

  /// The sentence in the app's language, for VoiceOver.
  var sentence: String {
    let (key, count) = localization
    let format = NSLocalizedString(key, tableName: "MultipastaSettings", comment: "")
    guard let count else {
      return format
    }
    return String(format: format, count)
  }

  /// The sentence for SwiftUI, so that snapshots follow the view's locale.
  var text: Text {
    switch self {
    case .added(let count):
      return Text("ListHUDAdded \(count)", tableName: "MultipastaSettings")
    case .newList:
      return Text("ListHUDNewList \(1)", tableName: "MultipastaSettings")
    case .nothingToAdd:
      return Text("ListHUDNothingToAdd", tableName: "MultipastaSettings")
    case .onlyText:
      return Text("ListHUDOnlyText", tableName: "MultipastaSettings")
    case .hiddenContent:
      return Text("ListHUDHidden", tableName: "MultipastaSettings")
    case .paused:
      return Text("ListHUDPaused", tableName: "MultipastaSettings")
    case .ignored:
      return Text("ListHUDIgnored", tableName: "MultipastaSettings")
    }
  }
}

@MainActor
final class ListCopyHUD {
  static let visibleDuration: TimeInterval = 1.2

  private var panel: NSPanel?
  private var hostingView: NSHostingView<ListCopyHUDView>?
  private var generation = 0

  func show(_ message: ListCopyHUDMessage) {
    generation += 1
    let shownGeneration = generation
    let panel = panel ?? QuitGuardHUD.makeHUDPanel()
    self.panel = panel

    let content = ListCopyHUDView(message: message)
    if let hostingView {
      hostingView.rootView = content
    } else {
      let hostingView = NSHostingView(rootView: content)
      panel.contentView = hostingView
      self.hostingView = hostingView
    }

    let size = hostingView?.fittingSize ?? .zero
    let frontmost = NSWorkspace.shared.frontmostApplication
    let screen = frontmost.flatMap { QuitGuardHUD.screen(ofFrontmostWindowOf: $0.processIdentifier) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    if let frame = screen?.frame {
      panel.setFrame(
        NSRect(
          x: (frame.midX - size.width / 2).rounded(),
          y: (frame.midY - size.height / 2).rounded(),
          width: size.width,
          height: size.height
        ),
        display: true
      )
    }

    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if panel.isVisible || reduceMotion {
      // Already on screen (a quick second press) or no motion wanted: swap the text in place.
      panel.alphaValue = 1
      panel.orderFrontRegardless()
    } else {
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.12
        panel.animator().alphaValue = 1
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration) { [weak self] in
      if self?.generation == shownGeneration {
        self?.hide()
      }
    }

    let sentence = message.sentence
    announceForAccessibility({ sentence }, priority: .high)
  }

  func hide() {
    guard let panel, panel.isVisible else {
      return
    }
    generation += 1
    let hiddenGeneration = generation
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      panel.orderOut(nil)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // A new message may have arrived while fading out.
        if self?.generation == hiddenGeneration {
          self?.panel?.orderOut(nil)
        }
      }
    }
  }
}

/// A symbol and one line on the system HUD material, like the ⌘Q guard HUD.
struct ListCopyHUDView: View {
  let message: ListCopyHUDMessage
  /// Liquid Glass on macOS 26 and later; snapshots turn it off (offscreen can't draw glass).
  var prefersGlass = true

  private let cornerRadius: CGFloat = 16
  private let foreground = Color(nsColor: .labelColor)

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: message.symbolName)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)

      message.text
        .font(.system(size: 14, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, 18)
    .padding(.vertical, 13)
    .modifier(QuitGuardHUDBackground(cornerRadius: cornerRadius, prefersGlass: prefersGlass))
    .padding(20) // room for the window shadow
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("list-copy-hud")
  }
}

#Preview {
  ListCopyHUDView(message: .added(count: 3))
}
