---
title: Inbox
description: The Inbox collects action items from meetings, watchers, chats and agents until you mark them done or remove them.
section: Features
order: 10
---

The Inbox holds things that need a decision from you: action items from your meetings, and things your watchers or agents found, such as an email that needs a reply or an issue. Click your pet, then **Inbox** in the sidebar. The iPhone's Inbox tab shows the same groups. Swiping a row offers Remove, and tapping it opens the same page.

ironpet has no task list. If you tell your pet in the chat what you did, it can save that as a [memory](/docs/memory/) note instead.

## Items

An item has a title, optional notes and a due date, and links to every source it came from (a meeting, a mail or an issue URL).

The list has one group for each place items came from (Chat, Screen capture, Meeting and so on), with a count, newest first, one line per item. An **Open** button shows only for an item with a link. Click a row to open its page: the title, why the item exists with the chat it came from as a link, Done, Remove and Open, then the notes and the sources.

Items resolved today are listed at the end with the reason and the time. Their page says "Resolved by <who> at <time>" and shows the reason as evidence. An item resolved before ironpet stored the resolver shows "unknown".

**Done** and **Remove** both take it off the list, on the Mac and on the iPhone, and neither creates anything else.

## Where items come from

### Meetings

After a meeting summary, the action items marked `owner: Me` are added to the Inbox, and one bubble without buttons says how many.

- Items owned by someone else stay in the summary.
- Items without an owner, or already in the Inbox, are skipped.
- Turn this off under Settings → Meetings (`tasks.meetingSuggestions`).
- The **Show bubbles** switch under it (`tasks.meetingSuggestionBubbles`) skips only the bubble. The items and the notification are still added.

See [Meetings](/docs/meetings/).

### Chats and the screen

The Inbox scan reads the chat messages that are new and adds what you said you'd do or must act on, for example "remind me to renew the passport". With **Read screen text** on, it also reads the text of new screen captures, so a commitment typed in a chat app gets in.

It's off by default. Under Settings → Inbox (`tasks.inboxScan`) you set:

| Setting | Key | Default |
| --- | --- | --- |
| How often it runs | `tasks.inboxScanMinutes` | 30 minutes (5 to 1440) |
| Whether it reads screen text | `tasks.inboxScanScreen` | Off. Needs [screen capture](/docs/screen/). |
| Whether its bubble shows | `tasks.inboxScanBubbles` | On. Off skips only the bubble. |

- A run sends only the text since the last run: a chat's text to that chat's own agent, and screen text to the current chat's agent. The agent gets no tools and every permission is refused.
- The scan also keeps open items current. When a later message gives an item's missing link, due date or notes, the item gets that field. When a later message says an item is done ("merged it"), the item leaves the list under Resolved today, with the scan as resolver and a reason that names the message. When it is in doubt, it leaves the item open.
- An item already in the Inbox isn't added again, and one you removed or marked done doesn't come back.
- Apps on the screen capture skip list and secure fields are never read.

### Watchers

A script automation that watches your mail, Slack or GitHub can return `suggest_task` actions (see [Script actions](/docs/automations/#script-actions)). They show up as items marked "From &lt;automation name&gt;", with a link button when the watcher gave a URL, and one bubble per run without buttons. The text comes from outside, so it never reaches an agent.

### Agents

Agents use seven MCP tools:

| Tool | Arguments | What it does |
| --- | --- | --- |
| `inbox_list` | optional `source`, `since`, `include_resolved` | Lists items. |
| `inbox_get` | `id` | Returns the item with its origin and history. |
| `inbox_note` | `id`, `text` | Adds a note to an item. |
| `inbox_add` | `id`, `title`, `notes`, `due`, `url`, optional `same_as`, and an `origin` with `kind`, `ref` and `reason` | Adds or updates an item. |
| `inbox_done` | `id` | Marks an item done. |
| `inbox_resolve` | `id`, `reason`, optional `resolved_by` | Takes an item off the list. The reason is the evidence, such as "PR 398 merged, checked with gh", and must not be empty. |
| `inbox_remove` | `id`, optional `note` | Removes an item. |

- `inbox_add` with an `id` whose item is still in the Inbox updates it, so a follow-up mail that moves a date changes the item.
- `same_as` (or the same `url`) adds a second source to an existing item instead of a second item.
- An `id` whose item you removed or resolved is ignored, and so is a title that's already in the Inbox.
- A note stays with its item and goes when the item is done or removed.

## From the terminal

With the app running, you can do the same from the terminal. `IronPet` is the app's own executable, `/Applications/IronPet.app/Contents/MacOS/IronPet`, and isn't on your PATH, so call it by that path or add `alias IronPet=/Applications/IronPet.app/Contents/MacOS/IronPet` to your shell profile.

```bash
IronPet inbox list [--source KIND] [--since T] [--json]
IronPet inbox get <id>
IronPet inbox add --title TEXT [--notes TEXT] [--due YYYY-MM-DD] [--url URL]
IronPet inbox note <id> <text>
IronPet inbox done <id>
IronPet inbox remove <id> [--note TEXT]
```

- `list` prints one line per item, or JSON with `--json`. The other commands print JSON.
- `inbox add` takes the same path as `inbox_add`, with the source `cli`, so the same title is one item.
- `T` is an ISO 8601 date, `today`, `yesterday` or an age such as `6h` or `2d`.

For example:

```bash
IronPet inbox add --title "Renew the passport" --due 2026-12-15
```

## Automations on new items

An automation with the trigger `{"type": "inbox"}` runs once for each item that arrives after the automation was created. The item is in `{{item.id}}`, `{{item.title}}`, `{{item.notes}}`, `{{item.due}}`, `{{item.url}}`, `{{item.source}}` and `{{item.created}}`.

- Items already in the Inbox don't run it, and it doesn't run for an item it filed itself.
- A shell or prompt action an agent wrote waits for your approval as for any automation, and an item that arrives before the approval doesn't run it.
- In a shell action each item value is quoted.

See [Automations](/docs/automations/).

## On the iPhone

The iPhone's Inbox tab shows the same list. When the Mac runs an older version that doesn't serve it, the tab is empty instead of showing an error. See [iPhone](/docs/iphone/).

## Where items are kept

Items, and the ids each automation has added (kept for a year), are in `~/.ironpet/ironpet.db`, in the `task_suggestions`, `task_suggestion_sources`, `task_suggestion_keys` and `task_suggestion_resolved` tables.

## Upgrading from an earlier version

The Inbox replaces the task list, the board and the GTD views (contexts, areas, someday, tickler, projects, waiting-for, goals and the weekly review). The upgrade (migration 590) drops the task tables with no export, so tasks from an earlier version are gone.
