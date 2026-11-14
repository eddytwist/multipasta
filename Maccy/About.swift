import Cocoa

class About {
  private var links: NSMutableAttributedString {
    let text = NSLocalizedString("about_credits", comment: "")
    let string = NSMutableAttributedString(string: text,
                                           attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    let maccyRange = (text as NSString).range(of: "Maccy")
    if maccyRange.location != NSNotFound {
      string.addAttribute(.link, value: "https://github.com/p0deje/Maccy", range: maccyRange)
    }
    return string
  }

  private var credits: NSMutableAttributedString {
    let credits = NSMutableAttributedString(string: "",
                                            attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    credits.append(links)
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
  }
}
