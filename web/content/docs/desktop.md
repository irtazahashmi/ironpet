---
title: Desktop control
description: Let the agents you run in ironpet read and operate other Mac apps through Accessibility, with approval for anything risky.
section: Features
order: 8.5
---

Desktop control lets the agents you run in ironpet read and operate other Mac apps: read a window, press a button, fill a field, pick an option, press a key. It works through Accessibility, so there's nothing to install and no separate permission. It uses the Accessibility access ironpet already has.

It's off by default. Turn it on under **Settings → Screen → Desktop control**. macOS asks for Accessibility if ironpet doesn't have it yet.

Agents use it for what only an app's window can do. When a command, an API or a file does the job, they use that instead.

## The tools

Agents get twelve `desktop_*` MCP tools. The bundled `ironpet-desktop` skill tells them how to use them.

| Tool | What it does |
| --- | --- |
| `desktop_snapshot` | Reads a window live and returns an outline, one element per line, each with a ref. It can read one subtree, or list the elements with one role |
| `desktop_find` | Lists the elements that match a role, name or value |
| `desktop_press` | Presses a button, menu item, checkbox or link |
| `desktop_set_value` | Replaces the value of a text field |
| `desktop_type` | Inserts text at the caret |
| `desktop_focus` | Focuses an element, or raises a window |
| `desktop_select` | Picks an option in a popup, combo box, list, table or outline |
| `desktop_check` | Checks or unchecks a checkbox, switch or radio button |
| `desktop_expand` | Expands or collapses a disclosure triangle, outline row or popup |
| `desktop_key` | Presses a key or combo, such as <kbd>↩</kbd>, <kbd>⎋</kbd> or <kbd>⌘L</kbd>, in one app |
| `desktop_open_url` | Opens an http or https address in a new browser tab |
| `desktop_screenshot` | Takes a picture of one window, not the whole screen. Needs Screen Recording |

A ref belongs to the last read of a window and works only while its element is unchanged, so an agent reads the window again after it acts. ironpet sends no mouse events and doesn't move your pointer, so an element with no Accessibility action and no key for it can't be operated.

## Safety

These rules apply whatever the settings say:

- Password fields are never operated, and no key is sent while one has the focus. Password managers, apps on the screen capture exclusion list and private browser windows are never read or operated.
- Nothing works while screen capture is paused or the screen is locked.
- An action on an element or window whose text says send, pay, delete, submit or buy (and similar words such as purchase, check out and transfer) waits for you to press **Approve** in a bubble. **Reject**, or no answer in two minutes, fails the action.
- <kbd>⌘↩</kbd>, <kbd>⌘Q</kbd> and <kbd>⌘W</kbd> always wait for **Approve**. <kbd>↩</kbd> and other <kbd>⌘</kbd> combos also wait when the window or element says send, pay, delete, submit or buy. Letters, <kbd>⇥</kbd>, <kbd>⎋</kbd> and the arrows never ask.
- Only http and https addresses can be opened, never ones with a user name or password in them, and never hosts that screen capture is set never to read.

The chat's own approval card still applies on top of this, unless the agent's mode doesn't ask.

The check for words like "send" reads text, so a button with only an icon, or a label in another language, doesn't trigger it. See [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md) for the limits.

## The log

Every action is logged with its time, app, window, element, action and outcome. **Settings → Screen → Desktop control** lists the latest ones, and the log is kept for 30 days.
