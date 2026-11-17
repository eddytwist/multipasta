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
- No network access at all: no update checks, no analytics, no crash reports, no accounts.
