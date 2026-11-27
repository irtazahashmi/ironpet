---
title: Screen help
description: Ask Ghost about a window or region, let agents search what you've seen, and let them operate other apps.
section: Features
order: 8
---

Ghost can look at your screen in three ways. Screenshot shortcuts open a chat about what you're looking at. Screen capture, off by default, keeps searchable text of the windows you use. Desktop control, also off by default, lets your agents operate other Mac apps.

## Screenshot shortcuts

| Shortcut | What it does |
| --- | --- |
| <kbd>⇧⌥⌘G</kbd> | Captures the front window and opens a chat with the screenshot attached |
| <kbd>⌃⌥⌘G</kbd> | Captures a region you drag and opens a chat with it attached |

These need Screen Recording permission. You can change or turn off both shortcuts in Settings; see [Configuration](/docs/configuration/).

Opening chat with text selected in another app, when Accessibility is already allowed, attaches that selection as a removable chip so you can ask about it without pasting.

## Screen capture

When on, ironpet reads the text of the window you're using through Accessibility, redacts secrets, and keeps what changed in `~/.ironpet/ironpet.db` for 30 days. The agents you run in ironpet search it with two MCP tools, `screen_search` and `screen_window`. Nothing leaves your Mac except through those tools. With the switch off nothing is read, and macOS shows no permission prompt.

Turn it on under **Settings → Screen**. macOS asks for Accessibility then.

### What is read and when

ironpet reads the focused window's text: static text, headings, text areas and text fields. Buttons and similar controls are read for their name only. Password fields are read for their role and nothing else. A capture runs shortly after an app switch, a pause in typing, the end of scrolling, a click, and every 10 seconds when nothing else happened. Key events are used only for timing. No key is read.

A window with no readable text is skipped, unless you turn on the screenshot fallback. ironpet then screenshots that window, reads the text with Apple Vision on your Mac, and drops the image without saving it.

### Redaction and exclusions

Before storage, rules replace secrets with `[redacted:<kind>]`: provider API keys and tokens, JWTs, private key blocks, passwords in URLs, `password=` and `.env`-style assignments, card and bank numbers, and long random strings. The rules are patterns, so a secret in a form they don't know can pass through.

Never captured, whatever the settings say: password managers and authenticator apps, the lock screen, private browser windows, and `file:`, `data:`, `javascript:`, `blob:`, `about:` and browser-internal URLs.

### Settings

| Setting | Key | Notes |
| --- | --- | --- |
| Screen capture | `screenCapture.enabled` | Default off |
| Screenshot fallback | `screenCapture.ocr` | Default off. Reads windows with no text from a screenshot, on this Mac. Asks for Screen Recording when turned on |
| Apps never captured | `screenCapture.excludedApps` | Bundle ids or app names, also under **Never capture** in Settings |
| Retention | `screenCapture.retentionDays` | Default 30 |

Pause capture from the pet menu or Settings. The **Screen** section of the ironpet window lists the latest captures and searches everything stored. Settings has a **Delete all captures** button.

## Desktop control

Desktop control lets the agents you run in ironpet read and operate other Mac apps through Accessibility. It needs nothing extra installed and uses the Accessibility access ironpet already has. Turn it on under **Settings → Screen → Desktop control**.

Agents get twelve `desktop_*` MCP tools: they can read a window, find elements, press buttons, set or type text, pick options, tick checkboxes, expand rows, focus elements, press keys in one app, open web addresses in a browser, and take a screenshot of one window. The bundled `ironpet-desktop` skill describes them. ironpet sends no mouse events and doesn't move your pointer.

Safety rules that no setting overrides:

- Password fields are never operated. Password managers, apps on the screen capture exclusion list and private browser windows are never read or operated. Nothing works while capture is paused or the screen is locked.
- An action on an element or window whose text says send, pay, delete, submit or buy (and similar words such as purchase, check out and transfer) waits for you to press **Approve** in a bubble. **Reject**, or no answer in two minutes, fails the action.
- Pressing <kbd>⌘↩</kbd>, <kbd>⌘Q</kbd> or <kbd>⌘W</kbd> always waits for **Approve**.
- Only http and https addresses can be opened.
- Every action is logged. Settings → Screen → Desktop control lists the latest ones, and the log is kept for 30 days.

The chat's own approval card still applies on top of this, unless the agent's mode doesn't ask.

The check for words like "send" reads text, so a button with only an icon, or a label in another language, doesn't trigger it. See [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md) for the limits.
