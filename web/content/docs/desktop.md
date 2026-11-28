---
title: Desktop control
description: Let the agents you run in ironpet read and operate other Mac apps through Accessibility, with approval for anything risky.
section: Features
order: 8.5
---

Desktop control lets the agents you run in ironpet read and operate other Mac apps: read a window, press a button, fill a field, pick an option, press a key, click and scroll. It works through Accessibility, so there's nothing to install and no separate permission. It uses the Accessibility access ironpet already has.

It's off by default. Turn it on under **Settings → Screen → Desktop control**. macOS asks for Accessibility if ironpet doesn't have it yet.

| Setting | Key | Notes |
| --- | --- | --- |
| Desktop control | `desktopControl.enabled` | Default off |

Agents use it for what only an app's window can do. When a command, an API or a file does the job, they use that instead.

## The tools

Agents get fourteen `desktop_*` MCP tools. The bundled `ironpet-desktop` skill tells them how to use them.

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
| `desktop_click(ref or app, window?, x?, y?, button?, count?, modifiers?)` | Clicks with the mouse, for controls that ignore `desktop_press`, such as the drop-downs of web pages. With `ref` it clicks the centre of the element. With `app` and `x`, `y` it clicks that point, in points from the window's top-left corner. `button` is `left` or `right`, `count` 2 is a double click, and `modifiers` lists `cmd`, `shift`, `opt` or `ctrl` |
| `desktop_scroll(ref or app, window?, x?, y?, direction, amount?)` | Scrolls the mouse wheel over an element or over a window (its centre unless `x`, `y` are given). `direction` is `up`, `down`, `left` or `right`, and `amount` counts lines (default 3, at most 20) |
| `desktop_open_url(url, browser?)` | Opens an http or https address in a new tab of the named browser, else the frontmost browser, else the default one |
| `desktop_screenshot(app, window?)` | Takes a picture of one window, not the whole screen. Needs Screen Recording |

A ref belongs to the last read of a window and works only while its element is unchanged, so an agent reads the window again after it acts. A tool that gets a stale or unknown ref says so and asks for a new snapshot. Two identical elements get refs ending in `~2`, `~3` and so on.

Actions use Accessibility, except `desktop_key`, `desktop_click` and `desktop_scroll`, which post key, mouse and scroll events to one app's process, and `desktop_open_url`. Agents try `desktop_press` first and click only when an element ignores it.

A click or scroll is posted to the app's process, not to the whole system, so it doesn't move your pointer. The result gives the screen point and says whether the pointer moved. The app's window is raised first when a click needs it. After a scroll, refs can be stale, so the agent reads the window again.

## Safety

These rules apply whatever the settings say:

- Password fields are read for their role only and never operated, and no key is sent while one has the focus.
- Password managers, apps on the screen capture exclusion list, private browser windows and the addresses screen capture never reads are never read or operated. See [Never captured](/docs/screen/#never-captured).
- Nothing works while screen capture is paused or the screen is locked.
- An action on an element, or in a window, whose text says send, pay, delete, submit or buy (and forms of those words, plus purchase, check out and transfer) waits for you to press **Approve** in a bubble. **Reject**, or no answer in two minutes, fails the action.
- `desktop_key` always waits for **Approve** for <kbd>⌘↩</kbd>, <kbd>⌘Q</kbd> and <kbd>⌘W</kbd>. It also waits for <kbd>↩</kbd> or any other <kbd>⌘</kbd> combo when the focused window or element says send, pay, delete, submit or buy. A plain letter, <kbd>⇥</kbd>, <kbd>⎋</kbd> or an arrow never asks.
- `desktop_click` follows the same rules as an action. It refuses a point outside the window, an element that is not inside the window's visible area, and anything that is, or sits over, a password field. A click waits for **Approve** when the element, the element under the point or the window title says send, pay, delete, submit or buy, and it checks again after you answer. `desktop_scroll` presses nothing, so it never asks, but the app, window and password rules apply to it too.
- `desktop_open_url` opens only http and https addresses whose host isn't on the screen capture deny list, and refuses addresses with a user name or password in them.

The chat's own approval card still applies on top of this: a `desktop_*` call asks first whatever the agent's mode, unless the agent itself doesn't ask in the mode you picked (Claude Code's bypassPermissions, for example). The **Approve** bubble above applies either way.

The check for words like "send" reads text, so a button with only an icon, or a label in another language, doesn't trigger it. See [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md) for the limits.

## The log

Every action is logged with its time, app, window, element role and name, action and outcome. **Settings → Screen → Desktop control** lists the latest ones. The log is the `desktop.action` kind of the activity log in `~/.ironpet/ironpet.db`, and it's kept for 30 days.
