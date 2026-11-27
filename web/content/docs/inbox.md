---
title: Inbox
description: The Inbox collects action items from meetings, watchers, chats and agents until you mark them done or remove them.
section: Features
order: 10
---

The Inbox holds things that need a decision from you: action items from your meetings, and things your watchers or agents found, such as an email that needs a reply or an issue. Click Ghost, then **Inbox** in the sidebar. The iPhone's Inbox tab shows the same list.

ironpet has no task list. The Inbox replaced the earlier task list, board and GTD views. If you tell Ghost in the chat what you did, he can save that as a memory note instead.

## Items

An item has a title, optional notes and a due date, and links to every source it came from (a meeting, a mail or an issue URL). Click an item to expand everything stored about it. **Done** and **Remove** both take it off the list, on the Mac and on the iPhone.

## Where items come from

### Meetings

After a meeting summary, the action items marked `owner: Me` are added to the Inbox, and one bubble says how many. Items owned by someone else stay in the summary. Turn this off under Settings → Meetings (`tasks.meetingSuggestions`). See [Meetings](/docs/meetings/).

### Chats and the screen

The Inbox scan reads new chat messages and adds what you said you'd do or must act on, for example "remind me to renew the passport". It's off by default (`tasks.inboxScan`) and runs every 30 minutes when on. With **Read screen text** on (`tasks.inboxScanScreen`, off by default, needs screen capture), it also reads the text of new screen captures, so a commitment typed in a chat app gets in.

An item already in the Inbox isn't added again, and one you removed or marked done doesn't come back.

### Watchers

A script automation that watches your mail, Slack or GitHub can add items. They show up marked "From <automation name>", with a link button when the watcher gave a URL. See [Automations](/docs/automations/).

### Agents and the terminal

Agents can list, add, update, annotate and resolve items with the `inbox_*` MCP tools. With the app running, you can do the same from the terminal. `IronPet` is the app's own executable, `/Applications/IronPet.app/Contents/MacOS/IronPet`, and isn't on your PATH, so call it by that path or add `alias IronPet=/Applications/IronPet.app/Contents/MacOS/IronPet` to your shell profile:

```bash
IronPet inbox list
IronPet inbox add --title "Renew the passport" --due 2026-12-15
IronPet inbox done <id>
```

The full command list is in the [README](https://github.com/irtazahashmi/ironpet/blob/main/README.md#inbox).
