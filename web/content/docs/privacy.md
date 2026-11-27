---
title: Privacy
description: What stays on your Mac, what is off by default, and every network request ironpet can make.
section: Basics
order: 3
---

ironpet runs on your Mac with your user's permissions. It has no account, no server of its own and no API keys of its own: chat goes through the sign-in your agents already have. This page summarises what it touches. The full list, with every file and every risk, is in [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md).

## What stays local

- **Your data lives in `~/.ironpet`.** Settings, saved chats, memory, the Inbox, automation state, notifications and meeting recordings are all in that folder. See [Your data](/docs/your-data/).
- **The local server listens on `127.0.0.1` only.** Every request must carry a random 256-bit token from `~/.ironpet/token`, or it is refused.
- **Nothing outside `~/.ironpet` changes until you press Start** in the welcome window. After that, ironpet only writes the agent hook files you chose, the login item if you left it on, and Keychain items for tokens you save.
- **Hooks only report status.** They never block or fail your agents (one-second timeout, always succeed) and no longer approve anything. They report only agents you started yourself: a chat ironpet runs over ACP sets `IRONPET_ACP_RUN=1`, and the hook skips it.

## What goes to your agents

When you chat, ironpet sends your messages to the agent you picked, and from there to that agent's model provider, exactly as if you used the agent directly. Anything an agent reads through ironpet's tools (memory, screen captures when that is on, the Inbox, meeting summaries) also goes to that agent's provider.

**Memory learning is on by default.** Once an hour ironpet sends a chat's new messages back to the same agent that already had them, so it can save lasting facts as notes. No provider gets text it didn't already have, but each pass spends that agent's quota. Turn it off in Settings → Memory → **Learn from chats**.

## Approvals depend on the agent

The agent decides when to ask for permission. Approvals are ACP `session/request_permission` requests from the agent. ironpet shows a card for every request it receives, with exactly the options the agent offered, and answers none of them itself. It cannot force an agent to ask: an agent that runs a tool without asking, because of its own settings, an allow-list or a "never ask" mode, does so without a card. Check each agent's own permission settings before you rely on the cards.

## Off by default

| Feature | Turn on |
| --- | --- |
| GitHub PR and CI alerts | Welcome window, or ask your agent in Automations |
| Sentry alerts | `./scripts/configure_sentry.sh` |
| Share MCP sign-ins across folders | Right-click → Integrations (shows a warning first) |
| Remote API for the iPhone | Settings → Devices |
| Voice notes | Settings → Voice |
| Spoken messages (<kbd>⌃⇧V</kbd>) | Come with voice notes; change or clear the shortcut in Settings → Voice → Talk to the chat |
| Reading replies aloud | Settings → Voice → Speak replies. The default, Automatic, speaks only replies to a spoken message, so it needs voice notes too |
| Meeting transcripts | Settings → Meetings |
| Screen capture | Settings → Screen |
| Desktop control | Settings → Screen |
| Telegram | Settings → Integrations |
| Also show macOS notifications | Right-click your pet |

With a feature off, its permission is never requested. For example, with voice notes off the microphone is never opened and nothing is sent.

## Network requests ironpet makes

ironpet sends nothing anywhere on its own, except:

- **Update checks.** A release build checks GitHub once a day for a newer release and downloads it in the background. The request carries only a User-Agent with the app and updater versions, no identifier. Both can be turned off in Settings → General → Updates. A build from `install.sh` never checks.
- **A one-time Bun download**, only if you pick Claude Code, Codex or Pi without Node 22 on your `PATH` and click **Download Bun**. The file comes from GitHub and is unpacked only if its checksum matches.
- **GitHub and Sentry polling**, only if you turn those alerts on.
- **Voice notes, spoken messages, spoken replies and meeting transcripts**, only if you turn them on or press a reply's speaker button. Audio and reply text go to the transcription and speech server you choose, which can be a server on your own Mac.
- **Speaker recognition models.** Turning on speaker recognition downloads about 21 MB of models from Hugging Face once.
- **Telegram**, only if you turn it on. ironpet long-polls Telegram's Bot API for your own bot, so messages to and from it pass through Telegram's servers.
- **The remote API**, only if you turn it on. It opens a listener on the network address you pick, for your paired phone. On public Wi-Fi, keep it off.

## Screen capture and desktop control

Both are off by default. Screen capture reads the text of the window you're using through Accessibility, redacts secrets with pattern rules, and stores it in `~/.ironpet/ironpet.db` for 30 days. Password fields, password managers, private browser windows and the lock screen are never captured. Redaction is pattern based, so a secret in a form the rules don't know can pass through. See [Screen help](/docs/screen/).

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** button on the repository's Security tab instead of a public issue.
