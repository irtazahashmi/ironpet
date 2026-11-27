---
title: Memory
description: How Ghost learns about you, your projects and the people you work with, and how to see and edit what he keeps.
section: Features
order: 9
---

Ghost learns about you, your projects and the people you work with without being asked, and every new chat starts with what he knows. You can see every page he keeps in the Memory section of the ironpet window, and change or delete any of it.

## What Ghost keeps

Memory is a set of pages in `~/.ironpet/ironpet.db`: one for you, one per person, one per project, and one for anything else Ghost is told about, such as an organization, a topic or a tool. A page holds dated claims, such as "Prefers pnpm over npm", each with the day it was last said and where it came from (a chat, a meeting or an automation).

A project is its git repository, identified by its `origin` remote, so every worktree and clone of a repo shares one page. A folder without a remote has its own page. A ticket, issue or PR is never a page of its own: its facts go on the project it belongs to.

## How he learns

Once an hour, ironpet reads what is new since the last pass and sends it to the agent that already had it. Each chat's new messages go to that chat's agent, and a meeting summary goes to the agent that wrote it. The agent answers only with the facts it would save. It gets no tools and every permission request is refused. ironpet checks each claim, drops any that holds a key, token or password, and saves the rest.

A newer claim that contradicts an older one replaces it; the old one stays in the page's history. Claude Code uses its cheap `haiku` model for a pass, and other agents use their default. Each pass shows as Memory in Settings → Usage.

Meeting summaries, screen text and automation answers hold what other people said or what was on screen, so they can only add claims about people, never about you or a project.

Learning from the screen is off by default (`memory.learnFromScreen`). Turn all learning off with **Learn from chats** in Settings → Memory (`memory.reflect`). What is said while it's off is never read later.

## In chat

Every new chat starts with up to about 4 KB of your own claims, 6 KB of the current project's and 2 KB about people. Ask "what did we decide about…" and Ghost searches past chats with any agent, meeting summaries and transcripts, notes, and your screen captures when screen capture is on.

Say "forget that I use pnpm" and Ghost removes the claim and tells you what went. The removed claim stays in the page's history until you undo it.

## The Memory section

The Memory section sits in the ironpet window after Automations, with the brain icon. It's also on the phone, under More. It lists every page, newest update first, with chips for People, Projects, Organizations, Topics and Tools, and a search over names, aliases and fact text.

On a page you can:

- **Pin** a fact, so it can't be replaced. A replacement is added beside it instead.
- **Forget** a fact, or every fact on the page.
- Open the meeting or screen capture a fact came from.
- Follow links to related pages. <kbd>Esc</kbd> or <kbd>⌘[</kbd> goes back.

When two pages may be the same thing, such as "Rabbit Checkout" and "rabbit-checkout", a banner offers to merge them. Merging asks you to confirm and can't be undone.

**Clean up** (Mac only) proposes moving notes to the page they're about, merging duplicate pages, creating organization pages, and deleting empty pages. You approve or skip each proposal, and nothing changes before you approve.

## Settings → Memory

- The learning switch, the agent and model it uses, and how often it learns.
- Whether it reads the screen.
- **Export to Markdown** writes a copy of every page to `~/.ironpet/memory-export/` and opens it. Nothing reads that copy back.
- **Forget Everything…** deletes the claims, links, their index, old note files and the Markdown copies after you confirm. Chats and meetings stay.

The memory settings keys are listed in [Configuration](/docs/configuration/).
