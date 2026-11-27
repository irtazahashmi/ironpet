---
title: Your data
description: What ironpet keeps in ~/.ironpet, and what each file and folder holds.
section: Reference
order: 18
---

ironpet keeps everything in one folder, `~/.ironpet/`. Delete the folder to erase all of it, or see [Uninstall](/docs/uninstall/) to remove ironpet completely.

## What's in `~/.ironpet`

| Path | Contents |
| --- | --- |
| `config.json` | Your settings. See [Configuration](/docs/configuration/) |
| `automations.json` | Reminder, watcher and scheduled job definitions |
| `ironpet.db` | Memory pages and claims, memory's search index over chats, meetings and notes, and the memory change log (the `memory_*` tables; see [Memory](/docs/memory/)). Also Inbox items, automation state and logs, notifications, usage, background jobs (the `jobs` table), screen captures when that feature is on, remote devices, and the activity log behind the welcome back summary (`activity_events`): what ironpet announced, with an agent's one-line summary or waiting request but never your prompt. [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md) lists the exact fields |
| `threads/` | Saved chats, and the transcript of each background job |
| `screenshots/` | Screen captures you attached to chats; `attachments/` for files you attached (and large pastes as `pasted-text.txt`) |
| `meetings/` | One folder per meeting: WAV chunks, `transcript.md`, `summary.md` |
| `memory-export/` | Markdown copies of the memory pages, written by Settings → Memory → Export to Markdown; nothing reads them back |
| `memory/` | Notes from earlier versions, read once into the database and not read again |
| `prompts/` | The prompts Ghost sends to agents on its own: `<id>.md` is the text in use, `.defaults/` the default each one was made from. Edit them in Settings → Prompts; see [SPEC.md](https://github.com/irtazahashmi/ironpet/blob/main/SPEC.md#prompts) |
| `dashboards/` | One folder per dashboard (`manifest.json`, `main.js`, `storage.json`) and `approvals.json`, which holds what you approved for each |
| `telegram/files/` | Files and voice downloads from Telegram chats |
| `remote/` | Remote API identity key and files a paired phone uploaded |
| `scratch/` | Working folder for chats with no project; `scratch/memory/` for the learning pass |
| `runtime/` | Bun, only if you allowed the download |
| `backgrounds/` | Custom chat background images |
| `pets/` | Your pet library: every valid sprite sheet here shows in Settings → General → Pets. See [Pets](/docs/pets/#your-own-pets) |
| `pet/spritesheet.png` | Optional custom pet art (overrides the bundled Ghost when `pet.sprite` is unset) |
| `bin/ironpet-hook`, `port`, `token` | Hook bridge and local server credentials |

## How long things are kept

- **Notifications**: 90 days.
- **Screen captures**: 30 days by default (`screenCapture.retentionDays`).
- **Automation logs**: 14 days by default (`automations.logRetentionDays`).
- **Background jobs**: 30 days after they end (`jobs.retentionDays`).
- **The activity log** behind the welcome back summary: 30 days. It records what ironpet announced, with an agent's one-line summary or waiting request, but never your prompt. It's kept whether or not the summary is on, read only on this Mac, and never sent anywhere.
- **Meeting recordings**: until you delete them.

## Outside `~/.ironpet`

- **Agent configs**, only for the agents you chose to watch, with the originals backed up as `*.ironpet-backup`. See [Agents](/docs/agents/#how-watching-works).
- **Keychain items** for tokens and keys you save: `ironpet.sentry`, `ironpet.telegram`, `ironpet.voice`, and `ironpet.voiceprints` for speaker recognition.
- **Voiceprints**, when speaker recognition is on, encrypted in `~/Library/Application Support/IronPet/voices.enc`.
- **The login item**, if you left Launch at login on.
- **App preferences** (`dev.ironpet.app`), which hold the chat that was open when the app quit, your unsent draft, and the mode you picked for each agent.

[SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md) lists every file and field in detail.
