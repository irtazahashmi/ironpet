---
title: Desktop control
description: Let the agents you run in ironpet read and operate other Mac apps through Accessibility, with approval for anything risky.
section: Features
order: 8.5
---

Desktop control lets the agents you run in ironpet read and operate other Mac apps: read a window, press a button, fill a field, pick an option, press a key. It works through Accessibility, so there's nothing to install and no separate permission. It uses the Accessibility access ironpet already has.

It's off by default. Turn it on under **Settings → Screen → Desktop control**. macOS asks for Accessibility if ironpet doesn't have it yet.

| Setting | Key | Notes |
| --- | --- | --- |
| Desktop control | `desktopControl.enabled` | Default off |

Agents use it for what only an app's window can do. When a command, an API or a file does the job, they use that instead.

## The tools

Agents get twelve `desktop_*` MCP tools. The bundled `ironpet-desktop` skill tells them how to use them.

| Tool | What it does |
| --- | --- |
| `desktop_snapshot(app, window?, root?, role?, text?, depth?)` | Reads a window live and returns an outline, one element per line, with a ref on every line. `root` (a ref) reads a subtree, and `role` lists the elements with that role |
| `desktop_find(app, window?, role?, name?, value?)` | Lists the elements that match, each with a ref |
| `desktop_press(ref)` | Performs the element's press action, or its default action (confirm, pick, open) |
| `desktop_set_value(ref, text)` | Sets the value of a text field or other settable element |
| `desktop_type(ref, text)` | Focuses the element and inserts text at the caret, or appends it when only the whole value can be set |
| `desktop_focus(ref)` | Focuses an element, or raises a window |
| `desktop_select(ref, text?)` | Picks the option with that text in a popup, combo box, list, table or outline. Without `text`, selects the element itself |
| `desktop_check(ref, checked)` | Makes a checkbox, switch or radio button checked or unchecked. Does nothing when it's already in that state |
| `desktop_expand(ref, expand)` | Expands or collapses a disclosure triangle, outline row or popup. Does nothing when it's already in that state |
| `desktop_key(app, key, window?)` | Presses a key or combo, such as `return`, `escape`, `shift+tab` or `cmd+l`, in one app. The key goes to that app's process only |
| `desktop_open_url(url, browser?)` | Opens an http or https address in a new tab of the named browser, else the frontmost browser, else the default one |
| `desktop_screenshot(app, window?)` | Takes a picture of one window, not the whole screen. Needs Screen Recording |

A ref belongs to the last read of a window and works only while its element is unchanged, so an agent reads the window again after it acts. A tool that gets a stale or unknown ref says so and asks for a new snapshot. Two identical elements get refs ending in `~2`, `~3` and so on.

Actions use Accessibility, except `desktop_key`, which posts key events to one app's process, and `desktop_open_url`. ironpet sends no mouse events and doesn't move your pointer, so an element with no Accessibility action and no key for it can't be operated.

## Safety

These rules apply whatever the settings say:

- Password fields are read for their role only and never operated, and no key is sent while one has the focus.
- Password managers, apps on the screen capture exclusion list, private browser windows and the addresses screen capture never reads are never read or operated. See [Never captured](/docs/screen/#never-captured).
- Nothing works while screen capture is paused or the screen is locked.
- An action on an element, or in a window, whose text says send, pay, delete, submit or buy (and forms of those words, plus purchase, check out and transfer) waits for you to press **Approve** in a bubble. **Reject**, or no answer in two minutes, fails the action.
- `desktop_key` always waits for **Approve** for <kbd>⌘↩</kbd>, <kbd>⌘Q</kbd> and <kbd>⌘W</kbd>. It also waits for <kbd>↩</kbd> or any other <kbd>⌘</kbd> combo when the focused window or element says send, pay, delete, submit or buy. A plain letter, <kbd>⇥</kbd>, <kbd>⎋</kbd> or an arrow never asks.
- `desktop_open_url` opens only http and https addresses whose host isn't on the screen capture deny list, and refuses addresses with a user name or password in them.

The chat's own approval card still applies on top of this: a `desktop_*` call asks first whatever the agent's mode, unless the agent itself doesn't ask in the mode you picked (Claude Code's bypassPermissions, for example). The **Approve** bubble above applies either way.

The check for words like "send" reads text, so a button with only an icon, or a label in another language, doesn't trigger it. See [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md) for the limits.

## The log

Every action is logged with its time, app, window, element role and name, action and outcome. **Settings → Screen → Desktop control** lists the latest ones. The log is the `desktop.action` kind of the activity log in `~/.ironpet/ironpet.db`, and it's kept for 30 days.
