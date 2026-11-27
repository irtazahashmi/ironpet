---
title: Memory
description: How your pet learns about you, your projects and the people you work with, and how to see and edit what it keeps.
section: Features
order: 9
---

Your pet learns about you, your projects and the people you work with without being asked, and every new chat starts with what it knows. Chats are saved and can be reopened, and when you ask "what did we decide about…" it searches past chats, meetings and notes. You can see every page it keeps in the Memory section of the ironpet window or the phone app, and change or delete any of it.

## What your pet keeps

Memory is a set of pages in `~/.ironpet/ironpet.db`: one for you, one per person, one per project, and one for anything else your pet is told about, such as an organization, a topic or a tool. A page holds dated claims, such as "Prefers pnpm over npm", each with the day it was last said and where it came from (a chat, a meeting or an automation).

A project is its git repository, identified by its `origin` remote, so every worktree and clone of a repo shares one page. A folder without a remote has its own page.

A note goes on the page of what it is about, which can be a project, an organization, a topic or a tool, not only the repo a chat ran in. A ticket, issue or PR is never a page of its own: its facts go on the project it belongs to, with the reference kept in the note. A note that only says where one task stands, such as a PR waiting for review, is not kept.

Once, after updating, your pet moves notes it had filed under a repo to the page they are about, and logs each move so it can be undone.

## How it learns

Once an hour (`memory.digestMinutes`, 60 by default), ironpet reads what is new since the last pass and sends it to the agent that already had it:

- each chat's new messages go to that chat's agent,
- a meeting summary written since the last pass goes to the summary agent,
- when **Learn from the screen** is on (`memory.learnFromScreen`, off by default), the text of new screen captures goes to the learning agent too.

Screen text and merges go to the chat's agent, since it already reaches captures through its tools. If you pick an agent in Settings → Memory → Agent, they go only when that is the chat's agent. Automation answers are read when they arrive, by the agent that ran them. Telegram chats count as chats.

Claude Code uses its cheap `haiku` model for a pass, and other agents use their default. Each pass shows as Memory in Settings → Usage.

The agent answers only with the claims it would save, the people, organizations, projects, tools and topics the text names (at most 10 a pass), and the links it states between them. It gets no tools and a scratch folder, and every permission request is refused. ironpet checks each claim, drops any that holds a key, token or password, and saves the rest.

- **Replacing.** A newer claim that makes an older one wrong replaces it. The old claim leaves the page and stays in its history.
- **Merging facts.** A page that holds more than 30 claims (`memory.maxClaimsPerEntity`) is merged by the chat's agent: its oldest unpinned facts are combined into fewer. A pinned fact is never merged.
- **Ambiguous names.** When a name fits two people, ironpet asks you in the alerts rather than guessing which one it means.
- **Other people's words.** Meeting summaries, screen text and automation answers hold what other people said or wrote, or what was on screen, so they can only add claims about people, never about you or a project.
- **Repeats.** An automation answer that is its quiet reply, or the same as last time, is skipped.

Turn learning off with **Learn from chats** in Settings → Memory (`memory.reflect`). What is said while it's off, or to an agent other than the one you picked, is never read later.

## In chat

Every new chat starts with up to about 4 KB of your own claims, 6 KB of the current project's and 2 KB about people (the people the first message names, then the most recently noted). Claims are added newest first, and only whole claims.

Say "forget that I use pnpm" and your pet removes the claim and tells you what went. The removed claim stays in the page's history until you undo it.

### Memory tools

The agent in a chat can use these tools:

| Tool | What it does |
| --- | --- |
| `memory_remember` | Saves a claim |
| `memory_forget` | Removes a claim |
| `memory_merge` | Folds duplicate pages of one type into one (`keep`, `merge`); see [Merging pages](#merging-pages) |
| `memory_page` | Reads one page with its claims and where each came from |
| `memory_links` | Lists how a page links to others |
| `memory_search`, `memory_get` | Look up past chats with any agent (your messages and your pet's, not tool output), meeting summaries and transcripts, claims, and your screen captures when screen capture is on |

Only `memory_merge` asks for approval, because it can't be undone. The others run without asking when the agent names ironpet's server: they only write claims, and a forgotten claim is kept in history.

An automation running in its own session can use these tools too, but its claims are marked as coming from it, never go on your own page, and it can neither forget claims nor merge pages. A [background job](/docs/automations/#background-jobs) has them like your chat.

## The Memory section

The Memory section sits in the ironpet window after Automations, with the brain icon. It's also on the phone, under More, and the Mac and the phone use the same list, search and page code.

It lists every page that has a fact or a recorded mention, newest update first, with chips for People, Projects, Organizations, Topics and Tools, and a search over names, aliases, identifiers and fact text (case and accents ignored).

A person, organization, project, tool or topic your pet sees in a chat, a meeting summary or on screen gets a page at its first mention, even before any fact is filed on it. Such a page shows "Mentioned in N places, no notes yet" and lists the sources. A person appears in the list from their second mention.

A page shows its facts (pinned first), the facts it replaced under **Earlier**, and its links grouped by type. On a page you can:

- **Pin** a fact, so it can't be replaced. A replacement is added beside it instead.
- **Forget** a fact, or every fact on the page.
- Click a source chip under a fact to open the meeting or screen capture it came from.
- Click a link to open the linked page. The title row keeps the trail, and <kbd>Esc</kbd> or <kbd>⌘[</kbd> goes back.
- Copy the page's id with the copy button under the date, to paste in a chat or a note.

### Merging pages

When a page may be another page of the same thing, a banner on it names the other pages and their fact counts. For people that means the same first name; for other types a name, alias, acronym or spelling variant, such as "Rabbit Checkout" and "rabbit-checkout".

Its merge button asks you to confirm, then moves their facts and links onto the page you are on, keeps their names as aliases of it so a later note about that name lands there, and removes them. Facts keep their date, sources, pin and where they came from. The merge runs in one transaction, so a failure leaves every page as it was, and it can't be undone. Pages of any type merge, but only with pages of the same type.

An agent does the same with `memory_merge`, and a terminal with:

```bash
IronPet memory merge <keep> <other>...
```

The command needs the app running and prints the result as JSON.

### Clean up

**Clean up** (Mac only) proposes moving notes to the page they're about, merging pages that name one thing, creating organization pages, and deleting pages that are empty or are tickets. It asks the agent set in Settings → Memory when one is available. You approve or skip each proposal, a skipped one is not offered again, and nothing changes before you approve.

Project notes from a chat that named no project wait for it instead of landing on the chat's folder page.

## Settings → Memory

- The learning switch (**Learn from chats**), the agent and model it uses, how often it learns (every N minutes) and whether it reads the screen.
- A button that opens the Memory section.
- **Export to Markdown** writes a copy of every page to `~/.ironpet/memory-export/` and opens it. Nothing reads that copy back.
- **Forget Everything…** deletes the claims, links, their index, the old note files and the Markdown copies after you confirm. Chats and meetings stay.

The memory settings keys are listed in [Configuration](/docs/configuration/#memory).

## Earlier notes

Notes from earlier versions, in `~/.ironpet/memory/` (`me.md`, `people.md` and `projects/`), were moved into the database once, on the first launch of this version. Those files stay where they are and are not read again; you can delete them.
