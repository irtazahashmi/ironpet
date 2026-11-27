---
title: Dashboards
description: Ask Ghost for a small app of your own and it appears in the sidebar, with its own data and buttons that act.
section: Features
order: 10.5
---

A dashboard is a small app inside ironpet. Ask Ghost for one in the chat, such as "a board of my agents grouped by state" or "my inbox count", and Ghost writes it, plus the automation that feeds it when it needs fresh data. It appears as a row in the sidebar of the ironpet window. ironpet ships no example dashboards.

## What a dashboard can show

Dashboards are drawn with native components, not web pages: columns and rows, cards, text, stats, lists, tables, charts and buttons. A button can open a link, a file or the chat, change the dashboard's data, run what the dashboard is allowed to run, or send Ghost a message. A message shows in the chat as sent by the dashboard, and Ghost answers.

The sidebar row can show a number, such as how many items need you.

## What a dashboard can reach

A dashboard can reach nothing outside its sandbox unless it declares it and you approve. When a dashboard is added, ironpet lists what it asks for:

| Capability | What it allows |
| --- | --- |
| Run | Command-line prefixes, such as `gh pr list`, that run as you without a shell |
| Network | The hosts it may contact |
| Read | Your Inbox, alerts and agents |
| Write | Marking Inbox items done or removing them |
| Prompt | A button that sends Ghost a message |

When an edit adds a capability, ironpet asks again and marks the new one. **Deny** keeps what you approved before. Until you approve, the dashboard shows the error instead of the data.

## Changing and deleting

Each dashboard's header menu has **Change icon**, **Edit code**, **Capabilities** and **Delete**. You can also ask Ghost to change it. A dashboard lives in `~/.ironpet/dashboards/<id>/`: `manifest.json` (title, icon, colour, capabilities), `main.js` (the view) and `storage.json` (its own saved data, up to 256 KiB). Edit a file in any editor and the dashboard reloads within two seconds. Deleting a dashboard removes its folder, its icon and its approvals.

Automations can post fresh data to a dashboard, and an open dashboard updates without reopening. The format of `main.js` and the automation result are in the [README](https://github.com/irtazahashmi/ironpet/blob/main/README.md#dashboards).

## On the iPhone

The phone's More tab lists your dashboards at the top with the same icons, colours and counts, and draws the same view. The Mac runs the script, so a dashboard shows only while the Mac is reachable. Approving capabilities is done on the Mac.
