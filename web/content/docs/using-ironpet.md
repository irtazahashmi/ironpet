---
title: Using ironpet
description: Shortcuts, moving your pet, opening Settings, and finding your way around the ironpet window.
section: Basics
order: 2
---

Most of ironpet is one click or one shortcut away. Click your pet or press <kbd>⌥⌘G</kbd> to open the ironpet window, right-click it for the menu, and press <kbd>⌘,</kbd> for Settings.

## Everyday actions

| Action | How |
| --- | --- |
| Chat with your pet | <kbd>⌥⌘G</kbd> or click your pet. With text selected in another app, the selection attaches as context when Accessibility is already allowed |
| Ask about the front window / a region | <kbd>⇧⌥⌘G</kbd> / <kbd>⌃⌥⌘G</kbd> |
| See watched agents, alerts and the Inbox | Click your pet when something needs attention, or right-click → Show agents |
| Allow an action | **Allow** or <kbd>⌘↩</kbd> on the approval card |
| Move your pet | Drag it; it stays where you leave it |
| Open a record named in chat | Click its id, such as `meeting_9f3c1e` or `notif_…`. On the Mac the id opens that record in its section; on the iPhone it opens the record's details |
| Copy a record's id | A meeting, automation, capture, notification or memory page shows its id under the date. Click the copy button next to it, then paste the id in a chat or a note |
| Settings | <kbd>⌘,</kbd>, the Settings row in the ironpet window, right-click your pet → Settings…, or the Dock icon menu |
| Morning brief and recap | Create an automation with a `digest` action (`brief` or `recap`) in ironpet window → Automations, or ask your agent for one, and pick the time there. The bubble's **Open**, or the Today row, shows each item; click one to open its Inbox item, session, alert link or meeting. See [Automations](/docs/automations/) |
| Pair an iPhone | Settings → Devices: turn on the remote API and scan the QR code with the IronPet TestFlight app. See [iPhone](/docs/iphone/) |
| Make your pet do tricks (wave, dance, zoomies, nap, say something…) | Right-click your pet → Actions |

When you open the chat from an app that isn't about code (a browser, Slack), your pet asks which project the question is about. You can also pick **No project** for a general question.

## The ironpet window

The ironpet window has a sidebar with these sections:

- **Chat**: talk to a coding agent. See [Chat](/docs/chat/).
- **Agents**: every watched agent session, most urgent first. See [Agents](/docs/agents/).
- **Alerts**: PR, CI and Sentry alerts. See [Alerts](/docs/alerts/).
- **Notifications**: every bubble your pet showed. See [Notifications](/docs/notifications/).
- **Inbox**: things that need a decision from you. See [Inbox](/docs/inbox/).
- **Transcripts**: past meetings with their summary and transcript, plus **Ask** (with your pet's name), **Regenerate** and **Move to Trash**. See [Meetings](/docs/meetings/).
- **Screen**: recent screen captures, when screen capture is on. See [Screen help](/docs/screen/).
- **Actions** and **Automations**. See [Automations](/docs/automations/).
- **Today**, shown while a morning brief or recap is on.
- One row for each dashboard you asked your pet to build.

The Memory section, with the brain icon, sits after Automations. See [Memory](/docs/memory/).

The Settings row sits at the bottom of the sidebar and opens Settings in its own window.

The window is resizable and stays open on Chat when you switch apps.

### Switching sections

<kbd>⌘1</kbd> to <kbd>⌘9</kbd> select the Nth visible sidebar row. This works even while the chat field has focus. By default the numbers go to Chat, Agents, Alerts, Notifications, Inbox, Transcripts, Screen, Actions and Automations. Today, listed last, has no number. A hidden section has no number, and the others renumber.

### Arranging the sidebar

Drag an icon to move it. Right-click the sidebar for a list of every section with a check mark, and choose one to show or hide it. Chat can't be hidden. A hidden section still opens from a link that leads to it, such as a notification, and returns to its place when you show it again. The order and the hidden sections are kept on this Mac.

### Collapsing the sidebar

<kbd>⌃⌘S</kbd> shrinks the sidebar to a 78 pt rail of section icons and back. Hovering an icon briefly shows its name and its <kbd>⌘</kbd> number, and count badges stay on the icons. You can also drag the sidebar's edge: narrower than about 117 pt collapses it, and dragging the rail's edge wider expands it. ironpet remembers the expanded width (156 to 300 pt) and whether the sidebar was collapsed.

## Settings

Settings opens in its own window with these pages in a sidebar: General, Memory, Inbox, Prompts, Automations, Integrations, Voice, Meetings, Usage, Screen and Devices. It reopens on the last page you used. Everything you set there is stored in `~/.ironpet/config.json`; see [Configuration](/docs/configuration/).

## Dashboards

Ask your pet for a small app of your own, such as "a board of my agents grouped by state", and it appears as an icon in the sidebar with its own saved data and buttons that act. A dashboard can only reach what it declares and you approve. See [Dashboards](/docs/dashboards/).

## Welcome back

When you come back after being away (5 minutes by default, the same idle time as the break reminders, or after the Mac slept), your pet sums up what happened meanwhile in one bubble instead of the ones you missed: "demo-app is waiting for you", "CI failed: you/demo-app #84", "2 agents finished". Each line opens what it names. It is built from what ironpet already recorded on your Mac, so no agent runs and nothing is sent anywhere. A call (any app using the microphone, even with meeting transcripts off) or a meeting recording doesn't count as away. Turn it off in Settings → General (`welcomeBack.enabled`).
