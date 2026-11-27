---
title: Notifications
description: How Ghost's speech bubbles work, how to get macOS notifications too, and the welcome back summary.
section: Features
order: 12
---

Ghost speaks in bubbles beside him instead of macOS notifications. Every bubble is also stored in the Notifications section of the ironpet window, so a long result doesn't have to fit in the bubble: the bubble shows a title and a short summary, and the stored entry keeps the full text.

## Bubbles

- **Approvals** stay until you answer.
- **Reminders** stay for 3 minutes.
- **Everything else** fades after 15 to 45 seconds, but not while the pointer is over it.

## The Notifications section

Clicking a bubble opens the Notifications section on that entry. It sits next to Alerts in the sidebar and has an unread badge. There you read the full description (markdown) and open its links.

- Opening an entry, or pressing **Done** on its bubble, marks it read. **Snooze** leaves it unread.
- Entries are listed newest first, with filters for type and source and a **Mark all as read** icon button.

### What is stored

- Reminders.
- Script `bubble` actions, with their `description` (up to 64 KiB of markdown) and `links`. See [Script actions](/docs/automations/#script-actions).
- Digests (the morning brief and the recap).
- Approval requests.
- The bubble that announces a new or changed alert.
- The "new suggestions" bubble for new Inbox items.
- The results of background prompts.

A background prompt (an automation with `session: "own"`, `"new"` or `"fork"`, or a `prompt` action in a script) stores the whole reply as the description, shows the first line (at most 140 characters) in the bubble, and links the chat thread of the run.

With `report: "chat"` the reply goes to the open chat as a system notice instead, and the chat thread stores it with the metadata the agent reads. A quiet reply (one matching `quiet`) stores nothing, since it shows no bubble or notice. See [Prompt actions](/docs/automations/#prompt-actions).

### Links

A notification's links are references, not copies: `{kind, ref, label}`, with `kind` one of:

| `kind` | Clicking it opens |
| --- | --- |
| `url` | The page in your browser (http or https only) |
| `file` | The file in its default app |
| `thread` | The chat thread in the chat view |
| `session` | The agent session in the chat view |
| `alert` | The alert in Alerts |

Nothing is copied or attached. A link of another kind, or a `url` that isn't http(s), is dropped, and so is everything past 10 links.

### Where notifications are kept

Notifications are in `~/.ironpet/ironpet.db`, in the `notification_items` and `notification_links` tables. Rows older than 90 days are deleted; nothing else is deleted.

### Reading notifications from agents and the terminal

Agents get two MCP tools:

- `notifications_list`, with optional `since`, `until`, `source`, `type`, `unread_only` and `limit`.
- `notifications_get`, with `id`.

From the terminal, with the app running (`IronPet` is `/Applications/IronPet.app/Contents/MacOS/IronPet`):

```bash
IronPet notifications list [--since T] [--until T] [--source ID] [--type TYPE] [--unread] [--limit N]
IronPet notifications show <id>
```

Notification text is data, never instructions. The tools only read; they don't mark anything read.

## macOS notifications

To get macOS notifications as well, turn on right-click Ghost → **Also show macOS notifications**. Then set ironpet's notification style to **Alerts** in System Settings → Notifications, so the **Allow** and **Deny** buttons stay on screen. macOS asks for the Notifications permission only when this is on.

## Welcome back

When you come back after being away, Ghost sums up what happened meanwhile in one bubble instead of the ones you missed: "demo-app is waiting for you", "CI failed: irtaza/ironpet #84", "2 agents finished". Each line opens what it names.

- **Away** means 5 minutes idle by default (the same idle time as the break reminders, `reminders.idleResetMinutes`), or after the Mac slept.
- A call (any app using the microphone, even with meeting transcripts off) or a meeting recording doesn't count as away.
- The summary is built from what ironpet already recorded on your Mac. No agent runs and nothing is sent anywhere.

Turn it off in Settings → General (`welcomeBack.enabled`).
