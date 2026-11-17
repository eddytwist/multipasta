import Cocoa

class About {
  // Multipasta: the About window links to the project. Maccy's MIT notice ships in the app's
  // LICENSE file.
  static let repository = "github.com/eddytwist/multipasta"

  private var credits: NSMutableAttributedString {
    let credits = NSMutableAttributedString(
      string: Self.repository,
      attributes: [
        .foregroundColor: NSColor.labelColor,
        .link: "https://\(Self.repository)"
      ]
    )
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
  }
}
