import AppKit
import SwiftUI

// Multipasta: the "Hold ⌘Q to quit <App>" HUD.
//
// A borderless, non-activating panel that never takes focus or clicks. It is centred on the
// screen of the guarded app's frontmost window and fades out when the hold is cancelled.
@MainActor
final class QuitGuardHUD {
  private var panel: NSPanel?
  private var hostingView: NSHostingView<QuitGuardHUDContent>?
  private var generation = 0
  /// The hold the HUD is showing, so that a late hide of an older hold leaves it alone.
  private var shownHoldID: UInt64?

  /// Shows the HUD for a hold that started at `start`; the ring is computed from that date.
  func show(app: QuitGuardStateMachine.App, start: Date, holdID: UInt64) {
    generation += 1
    shownHoldID = holdID
    let shownGeneration = generation
    let panel = panel ?? makePanel()
    // A new identity per hold, so nothing from the previous hold carries over.
    let content = QuitGuardHUDContent(appName: app.name, start: start, isActive: true)
    if let hostingView {
      hostingView.rootView = content
    } else {
      let hostingView = NSHostingView(rootView: content)
      panel.contentView = hostingView
      self.hostingView = hostingView
    }

    let size = hostingView?.fittingSize ?? .zero
    let screen = Self.screen(ofFrontmostWindowOf: app.processIdentifier) ?? NSScreen.main ?? NSScreen.screens.first
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

    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      panel.animator().alphaValue = 1
    }

    // Safety net: never leave the HUD on screen if a hide got lost.
    DispatchQueue.main.asyncAfter(deadline: .now() + QuitGuardStateMachine.holdDuration + 2) { [weak self] in
      if self?.generation == shownGeneration {
        self?.hide()
      }
    }

    let sentence = Self.sentence(appName: app.name)
    announceForAccessibility({ sentence }, priority: .high)
  }

  /// Hides the HUD if it is showing hold `holdID`.
  func hide(holdID: UInt64, animated: Bool = true) {
    guard Self.shouldHide(requestedHoldID: holdID, shownHoldID: shownHoldID) else {
      return
    }
    hide(animated: animated)
  }

  nonisolated static func shouldHide(requestedHoldID: UInt64, shownHoldID: UInt64?) -> Bool {
    requestedHoldID == shownHoldID
  }

  /// Hides the HUD whatever hold it shows.
  func hide(animated: Bool = true) {
    shownHoldID = nil
    guard let panel, panel.isVisible else {
      return
    }

    generation += 1
    let hiddenGeneration = generation
    guard animated else {
      orderOut()
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // A new hold may have started while fading out.
        if self?.generation == hiddenGeneration {
          self?.orderOut()
        }
      }
    }
  }

  private func orderOut() {
    panel?.orderOut(nil)
    // Stop the ring's timeline while hidden.
    if let hostingView {
      var content = hostingView.rootView
      content.isActive = false
      hostingView.rootView = content
    }
  }

  static func sentence(appName: String) -> String {
    String(
      format: NSLocalizedString("QuitHoldToQuit %@", tableName: "MultipastaSettings", comment: ""),
      appName
    )
  }

  private func makePanel() -> NSPanel {
    let panel = Self.makeHUDPanel()
    self.panel = panel
    return panel
  }

  /// A borderless, non-activating, click-through panel above other windows on every Space.
  /// Also used by the list copy HUD.
  static func makeHUDPanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
    return panel
  }

  /// The screen that holds most of the app's frontmost normal window.
  static func screen(ofFrontmostWindowOf pid: pid_t) -> NSScreen? {
    guard let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return nil
    }

    // The list is ordered front to back.
    let window = windows.first { info in
      (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
    guard let boundsInfo = window?[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsInfo),
          let primaryHeight = NSScreen.screens.first?.frame.height else {
      return nil
    }

    // Window bounds have a top-left origin on the primary screen; NSScreen frames bottom-left.
    let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    return NSScreen.screens.max { lhs, rhs in
      lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
    }
  }
}

private extension NSRect {
  var area: CGFloat { isNull ? 0 : width * height }
}

/// Drives the ring for one hold from its start date: a smooth fill over the hold duration, or
/// four steps without animation when Reduce Motion is on.
struct QuitGuardHUDContent: View {
  let appName: String
  let start: Date
  var isActive: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let reducedMotionSteps = 4.0

  var body: some View {
    Group {
      if !isActive {
        // Hidden: no timeline running.
        QuitGuardHUDView(appName: appName, progress: 1)
      } else if reduceMotion {
        let step = QuitGuardStateMachine.holdDuration / Self.reducedMotionSteps
        TimelineView(.periodic(from: start, by: step)) { context in
          QuitGuardHUDView(appName: appName, progress: Self.steppedProgress(start: start, at: context.date))
        }
      } else {
        TimelineView(.animation(minimumInterval: nil, paused: !isActive)) { context in
          QuitGuardHUDView(appName: appName, progress: Self.progress(start: start, at: context.date))
        }
      }
    }
    .id(start)
  }

  static func progress(start: Date, at date: Date) -> Double {
    min(max(date.timeIntervalSince(start) / QuitGuardStateMachine.holdDuration, 0), 1)
  }

  static func steppedProgress(start: Date, at date: Date) -> Double {
    // A small tolerance so a tick that lands a hair early still counts as the next step.
    let steps = reducedMotionSteps
    return min((progress(start: start, at: date.addingTimeInterval(0.02)) * steps).rounded(.down) / steps, 1)
  }
}

/// One line with a progress ring, on the system HUD material (Liquid Glass on macOS 26).
/// Only the app name is truncated when it's long, never the instruction around it.
struct QuitGuardHUDView: View {
  let appName: String
  let progress: Double
  /// Liquid Glass on macOS 26 and later, the `.hudWindow` material otherwise. Snapshots turn
  /// it off because offscreen rendering can't draw glass.
  var prefersGlass = true

  @Environment(\.locale) private var locale

  private let cornerRadius: CGFloat = 16
  // A concrete label colour rather than `.primary`: on glass, hierarchical styles adapt to
  // whatever is behind the HUD and the ring and the text could end up in different colours.
  private let foreground = Color(nsColor: .labelColor)

  var body: some View {
    let parts = QuitGuardHUDText.parts(locale: locale)
    HStack(spacing: 12) {
      ZStack {
        Circle()
          .stroke(foreground.opacity(0.18), lineWidth: 3.5)
        Circle()
          .trim(from: 0, to: progress)
          .stroke(foreground, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      .frame(width: 20, height: 20)

      HStack(spacing: 0) {
        Text(verbatim: parts.prefix)
          .fixedSize()
        Text(verbatim: appName)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(-1)
        Text(verbatim: parts.suffix)
          .fixedSize()
      }
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(foreground)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 13)
    .frame(maxWidth: 560)
    .modifier(QuitGuardHUDBackground(cornerRadius: cornerRadius, prefersGlass: prefersGlass))
    .padding(20) // room for the window shadow
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: parts.prefix + appName + parts.suffix))
  }
}

/// "Hold ⌘Q to quit %@" split around the app name, from the table of the view's locale
/// (so snapshots can render any language), falling back to the app's language.
nonisolated enum QuitGuardHUDText {
  static func parts(locale: Locale) -> (prefix: String, suffix: String) {
    let key = "QuitHoldToQuit %@"
    let table = "MultipastaSettings"
    var format = NSLocalizedString(key, tableName: table, comment: "")
    if let language = locale.language.languageCode?.identifier,
       let path = Bundle.main.path(forResource: language, ofType: "lproj"),
       let bundle = Bundle(path: path) {
      format = bundle.localizedString(forKey: key, value: format, table: table)
    }
    guard let range = format.range(of: "%@") else {
      return (format + " ", "")
    }
    return (String(format[..<range.lowerBound]), String(format[range.upperBound...]))
  }
}

/// Also used by the list copy HUD.
struct QuitGuardHUDBackground: ViewModifier {
  let cornerRadius: CGFloat
  let prefersGlass: Bool

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *), prefersGlass {
      content
        // Tinted with the window background so the label colour stays readable in light and
        // dark mode over any backdrop.
        .glassEffect(
          .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)),
          in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    } else {
      content
        .background {
          HUDMaterialView()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }
  }
}

/// `.hudWindow` material kept active: the HUD belongs to a background app, and an inactive
/// material would turn flat grey.
private struct HUDMaterialView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

#Preview {
  QuitGuardHUDView(appName: "Terminal", progress: 0.62)
}
