---
title: Agents
description: How Ghost watches your coding agents, what his states mean, and how to jump to a session.
section: Features
order: 4
---

Ghost watches the coding agents you start yourself and shows you which ones need you. Sessions report to him through hooks, and the Agents section of the ironpet window lists every one, most urgent first.

## Which agents

ironpet can watch Cursor (IDE and CLI), Claude Code, Codex, Gemini CLI, GitHub Copilot and Pi. Only the agents installed on your Mac are offered. You choose them in the welcome window on first launch, and you can change them later in Settings → General.

## How watching works

When you turn on watching for an agent, ironpet adds a small hook to that agent's own config. The hook calls `~/.ironpet/bin/ironpet-hook`, which reports the session's status to ironpet over `127.0.0.1` with a token.

| File | Agent |
| --- | --- |
| `~/.cursor/hooks.json` | Cursor |
| `~/.claude/settings.json` | Claude Code |
| `~/.codex/hooks.json` | Codex. Codex asks you to trust the hooks in its `/hooks` screen before it runs them |
| `~/.gemini/settings.json` | Gemini CLI |
| `~/.copilot/hooks/ironpet.json` | GitHub Copilot (a file ironpet owns) |
| `~/.pi/agent/extensions/ironpet.ts` | Pi (a file ironpet owns) |

ironpet backs up each config it edits next to the original as `*.ironpet-backup`. Turning off watching for an agent removes its hook.

Hooks never slow down or block an agent: they have a one-second timeout and always succeed. They only report sessions you started yourself. A chat that ironpet runs for you over ACP sets `IRONPET_ACP_RUN=1`, and the hook skips it, so it isn't listed twice.

**Track coding agents** in Settings → General (`integrations.trackAgents`, on by default) turns all of it off at once. It removes ironpet's hooks from every agent, ignores hook events still arriving from running sessions, and hides the Agents section on the Mac and the iPhone. Your per-agent choices come back when you turn it on again.

## States and the badge

Ghost shows the most urgent state across your sessions, with a count badge:

- **Needs input**: an agent is waiting for you.
- **Failed**: a turn ended with an error.
- **Done**: a turn finished.
- **Working**: an agent is running.

## Speech bubbles

Ghost also tells you in a speech bubble next to him, with a one-line summary of what the agent did, such as "Edited 3 files · Fixed the flaky login test." See [Notifications](/docs/notifications/) for how long bubbles stay and how to get macOS notifications as well.

## Opening a session

Click Ghost when something needs attention, or right-click → Show agents, to open the Agents section. Clicking a session jumps to its iTerm tab, or opens its folder in the app that started the agent.

You can pick a fixed app instead under Settings → General (the `openIn` key). The picker offers Cursor, VS Code, Zed, Band, Windsurf, Xcode, Finder, Orca, cmux, T3 Code, herdr, Claude and Codex when they're installed, plus any custom editors you add in [Configuration](/docs/configuration/). Orca opens the session's worktree. cmux, T3 Code, herdr, Claude and Codex open the exact tab or thread of the session when the hook saw its id, and otherwise only bring the app forward.
