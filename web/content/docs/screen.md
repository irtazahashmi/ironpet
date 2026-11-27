---
title: Screen help
description: Ask your pet about a window or region, let agents search what you've seen, and let them operate other apps.
section: Features
order: 8
---

Your pet can look at your screen in three ways. Screenshot shortcuts open a chat about what you're looking at. Screen capture, off by default, keeps searchable text of the windows you use. Desktop control, also off by default, lets your agents operate other Mac apps; see [Desktop control](/docs/desktop/).

## Screenshot shortcuts

| Shortcut | What it does |
| --- | --- |
| <kbd>⇧⌥⌘G</kbd> | Captures the front window and opens a chat with the screenshot attached |
| <kbd>⌃⌥⌘G</kbd> | Captures a region you drag and opens a chat with it attached |

These need Screen Recording permission. You can change or turn off both shortcuts in Settings; see [Configuration](/docs/configuration/).

Opening chat with text selected in another app, when Accessibility is already allowed, attaches that selection as a removable chip so you can ask about it without pasting.

## Screen capture

Screen capture is off by default. When on, ironpet reads the text of the window you're using through Accessibility, with no rules for particular apps, redacts secrets, and keeps what changed in `~/.ironpet/ironpet.db` for 30 days. The agents you run in ironpet search it with two MCP tools, `screen_search` and `screen_window`. Nothing leaves your Mac except through those tools. With the switch off nothing is read, and macOS shows no permission prompt.

Turn it on under **Settings → Screen**. macOS asks for Accessibility then.

### What is read

Each capture is one walk of the focused window's accessibility tree. Static text, headings, text areas and text fields are read for their text. Controls such as buttons are read for their name only, so a toolbar's "Bold: off" is part of the tree but never part of a message's text. Password fields are read for their role and nothing else, and hidden elements are skipped.

A window with no readable text is skipped, unless you turn on the screenshot fallback. ironpet then screenshots that window, reads the text with Apple Vision on your Mac, and drops the image without saving it. Turning the fallback on asks macOS for Screen Recording.

### When

| Event | Capture runs |
| --- | --- |
| App switch or window focus change | 0.3 s later |
| Pause in typing | 0.5 s after the last key |
| End of scrolling | 0.4 s later |
| Click | 0.2 s later |
| Nothing else happened | Every 10 s |

Captures are at least 0.2 s apart, and nothing is captured per keystroke. Key events are used only for timing. No key is read.

### What is stored

ironpet stores the redacted accessibility tree as hashed nodes. Each element is one row keyed by a hash of its fields and its children, so a subtree that didn't change is stored once, and a capture is a root hash. A capture that adds one message writes that message's nodes and the elements above it, about 1.3 to 3 KB.

- **Blocks.** Messages, mail rows and list entries (an article, a list item or a row) are recorded as they first appear: the app's own name for the block, its date, and whether it's new, edited or sent. A block seen in the last 7 days isn't new again.
- **Drafts.** Text you type into a field is kept as one draft per field, updated in place. Typing alone stores no capture.
- **Pages.** A window with no such blocks, and a screenshot read, count as one block, the page, and store the lines that are new, with two lines of context.

Text is searchable with SQLite FTS5. Captures stored by earlier versions are deleted when you upgrade.

### Redaction

Before storage, every capture goes through rules that replace each secret with `[redacted:<kind>]`. They cover:

- AWS, GitHub, GitLab, Anthropic and other `sk-` keys
- Stripe, Slack, Google, npm and SendGrid keys
- JWTs and private key blocks
- `user:password@` in URLs, and secret query parameters
- `password=`, `token:` and `.env`-style assignments
- Card and bank numbers
- Long random strings

The rules are patterns, so a secret in a form they don't know can pass through. The code has a hook (`CapturePrivacyFilter`) for an on-device privacy filter on write and on read, but no filter ships yet.

### Never captured

Whatever the settings say, ironpet never captures password managers and authenticator apps, the lock screen, private browser windows, or `file:`, `data:`, `javascript:`, `blob:`, `about:` and browser-internal URLs. Secrets in a page address (`code`, `token`, `key`, `sig` and others) are stripped.

### Settings

| Setting | Key | Notes |
| --- | --- | --- |
| Screen capture | `screenCapture.enabled` | Default off |
| Screenshot fallback | `screenCapture.ocr` | Default off. Reads windows with no text from a screenshot, on this Mac. Asks for Screen Recording when turned on |
| Apps never captured | `screenCapture.excludedApps` | Bundle ids or app names, also under **Never capture** in Settings |
| Retention | `screenCapture.retentionDays` | Default 30. Older captures, and the stored tree nodes no remaining capture uses, are deleted |

Pause capture from the pet menu or Settings. The **Screen** section of the ironpet window lists the latest captures (time, app, window and first lines) and searches everything stored. Settings has a **Delete all captures** button.

### The tools

Agents read captures through two MCP tools. Both return only stored, redacted text.

| Call | Returns |
| --- | --- |
| `screen_search(query, app?, since?, until?, limit?)` | Hits with capture id, time, app, window title and a short snippet |
| `screen_window(since, until?, app?, window?)` | The change list, per window (see below) |
| `screen_window(id)` | An outline of that capture's window. For a screenshot read, its text |
| `screen_window(id, root)` | One subtree, by ref |
| `screen_window(id, role, text?)` | The elements with that role |

The change list holds, per window, up to 30 lines for blocks that were new, edited or sent, or are drafts. Each line has the time (with UTC offset), the list it's in, its label, its date, the capture id and a ref, and the list ends with a count of the rest. On the first capture of a window everything visible is new, so the list holds the 30 newest by time, preferring entries that have a date, and counts the others. A window without blocks is one entry, the page.

`since` and `until` take `today`, `yesterday`, a date, an ISO 8601 time or an age such as `90m`.

## Desktop control

Desktop control, off by default, lets your agents read and operate other Mac apps through Accessibility, with approval for anything that sends, pays or deletes. It has its own page: [Desktop control](/docs/desktop/).
