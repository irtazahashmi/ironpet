---
title: Chat
description: Talk to Cursor, Claude Code, Codex and other agents through your pet, and approve what they do.
section: Features
order: 5
---

Press <kbd>⌥⌘G</kbd> or click your pet to open the ironpet window on Chat. The chat talks to a coding agent over the [Agent Client Protocol](https://agentclientprotocol.com) (ACP) in your current project, using the agent's own sign-in.

## Which agents

Chat works with Cursor, Claude Code, Codex, Gemini CLI, OpenCode and any other agent from the [ACP registry](https://github.com/agentclientprotocol/registry) that you have installed. ironpet starts the agent from your own install, for example `cursor-agent acp` or `gemini --acp`. Claude Code, Codex and Pi have no ACP mode of their own, so ironpet runs a small bundled adapter on your Node 22 or newer, which drives your installed `claude`, `codex` or `pi`.

If an agent says you need to sign in, ironpet shows a button. For an agent that signs in over ACP it starts the sign-in there, and for a terminal sign-in it opens Terminal with the command the agent gave.

## Picking an agent, a model and a project

The chat has an agent picker and a model picker. The models come from the agent. ironpet detects the project folder you're working in. When you open the chat from an app that isn't about code, such as a browser or Slack, your pet asks which project the question is about, or you can pick **No project** for a general question. Work that isn't about code runs in `~/.ironpet/scratch`.

With several pets on, each pet runs its own chat, and the chat header switches between them. See [Pets](/docs/pets/).

## Approvals

File edits and shell commands wait for **Allow** or **Deny** whenever the agent asks for permission. The card appears in the chat, or right in your pet's bubble when the chat is closed. <kbd>⌘↩</kbd> allows.

ironpet adds no rules of its own. Whatever the agent asks about shows up as a card with the agent's own options, such as allow once, allow always or approve a plan. ironpet answers none of them itself.

Each card is an ACP `session/request_permission` request that you answer. An agent that never sends one runs its tools without a card, and ironpet can't change that. For example, `cursor-agent acp` runs commands on its own allow-list without asking, and asks for nothing at all when set to Run Everything. Check each agent's own permission settings before you rely on the cards. See [Privacy](/docs/privacy/).

## Modes

The chat's **Mode** picker lists the permission modes the agent itself offers. For Claude Code that's default, plan, acceptEdits, auto and bypassPermissions, for example. The chat starts in the mode you configured in that agent and remembers your pick per agent. ironpet adds no modes. An agent that offers no modes shows no picker.

## Steering and the queue

While a turn is running, a message you type goes into that turn when the agent supports steering. Otherwise it waits in the queue until the turn ends. **Stop** cancels the turn (ACP `session/cancel`).

## Saved chats

Chats are saved in `~/.ironpet/threads` and can be reopened from **Previous chats**. Reopening one loads the agent's own session again (ACP `session/load`). The agent process stays alive between messages. The chat that was open when the app quit reopens at launch.

## Attachments and context

- Opening chat with text selected in another app attaches that selection as a removable chip, when Accessibility is already allowed.
- <kbd>⇧⌥⌘G</kbd> and <kbd>⌃⌥⌘G</kbd> open a chat with a screenshot attached. See [Screen help](/docs/screen/).
- Hold <kbd>fn</kbd> with [Wispr Flow](https://wisprflow.ai) while the chat is open, and the dictation is sent automatically. With voice notes on, <kbd>⌃⇧V</kbd> sends what you say as a message in the same chat. See [Voice](/docs/voice/).
- A paste over 4000 characters or 60 lines becomes a `pasted-text.txt` attachment instead of staying in the input. Both limits are in Settings → General.

## Long chats

Claude Code keeps every session in one file that only grows. When that file passes 50 MB and the chat is idle, ironpet asks the old session for a short summary and continues in a fresh agent session. The chat stays one thread, with one line saying a fresh session started. Other agents are not rolled over. See `chat.sessionRolloverMB` in [Configuration](/docs/configuration/).

## MCP servers

Your pet's chat can use the MCP servers you have in Cursor (`~/.cursor/mcp.json`). The Cursor CLI stores MCP sign-ins per folder, so normally you sign in with `cursor-agent mcp login <name>` in each project.

Turn on right-click → Integrations → **Share MCP sign-ins across folders** to sign in once. Your pet then copies your sign-ins into whichever folder a chat runs in. It's off by default because it copies OAuth tokens; see [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md).

Read-only MCP tools (`get…`, `list…`, `search…`, `find…`) run freely. Any other MCP tool waits for **Allow / Deny**, and whatever the agent asks about shows a card.

## Using ironpet's tools from another agent

ironpet's chat agents get MCP tools for automations, the Inbox, memory and more. To add them to another agent, for example Claude Code, run:

```bash
claude mcp add ironpet -- /Applications/IronPet.app/Contents/MacOS/IronPet mcp
```

Other agents take the same command and argument in their MCP settings. ironpet doesn't edit their config files.

## Background jobs

For work that takes a while, such as "fix the flaky login test in ironpet", the chat agent can hand it to a background job instead of doing it in the chat. See [Automations](/docs/automations/#background-jobs).
