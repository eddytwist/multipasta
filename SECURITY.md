# Security Policy

## Reporting a vulnerability

Please don't open a public issue. Report it privately on GitHub: open the **Security** tab of this repository and
click **Report a vulnerability**. I'll reply as soon as I can.

Only the latest release gets fixes.

## What Multipasta changes on your Mac

- It keeps your clipboard history in its own database in `~/Library/Application Support/Multipasta/` and its settings
  in its own preferences (`com.eddytwist.Multipasta`). **Launch at login** adds it to your login items.
- With Accessibility allowed, it sends ⌘V to the front app when you paste an item, and ⌘C when you press the
  add-to-list shortcut (⇧⌘C by default), to copy the selected text into the list.
- While your ⌘Q list isn't empty, it runs a keyboard event tap that acts only on ⌘Q in the apps on that list. With an
  empty list there is no event tap. Key presses are never recorded or stored.
- It reads Maccy's clipboard history from Maccy's container only when you choose to import it. It works on a temporary
  copy, deletes the copy afterwards and never changes Maccy's data.
- It doesn't post notifications. Its feedback sounds are macOS interface sounds. The first launch after updating from
  0.1 or 0.2 reads its notification settings once, without asking, to keep your sound choice, and clears the
  notifications those versions left in Notification Center.
- It isn't sandboxed, because the ⌘Q guard needs to hold back key presses meant for other apps.
- It goes online only for updates, through [Sparkle](https://sparkle-project.org): once a day while **Check for updates
  automatically** is on (Settings → General), and when you click **Check for Updates…**. It downloads the update feed
  attached to this repository's latest GitHub release and, only after you click **Install Update**, the new version's
  disk image. GitHub sees your IP address, the app's version (in the User-Agent) and your preferred language, as with
  any download; no system profile is sent. The feed and the disk image are installed only if their EdDSA signatures
  match the public key built into the app; the update replaces the app in place and never installs silently. With the
  automatic check off, nothing goes online unless you click **Check for Updates…**. No analytics, no crash reports, no
  accounts.
- Because its certificate is self-signed (no Team ID), the app turns off the hardened runtime's library validation so
  it can load the Sparkle framework inside its own signed bundle. The consequence: a program that can already write
  into `/Applications/Multipasta.app` could swap a library inside it without breaking the app's signature check at
  launch, and inherit its Accessibility permission. Such a program would already be running with your account's
  rights; a Developer ID certificate would remove this trade-off.
