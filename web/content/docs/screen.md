---
title: Screen help
description: Ask Ghost about a window or region, let agents search what you've seen, and let them operate other apps.
section: Features
order: 8
---

Ghost can look at your screen in three ways. Screenshot shortcuts open a chat about what you're looking at. Screen capture, off by default, keeps searchable text of the windows you use. Desktop control, also off by default, lets your agents operate other Mac apps; see [Desktop control](/docs/desktop/).

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

Desktop control, off by default, lets your agents read and operate other Mac apps through Accessibility, with approval for anything that sends, pays or deletes. It has its own page: [Desktop control](/docs/desktop/).
