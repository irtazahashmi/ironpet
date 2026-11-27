---
title: Configuration
description: Every key in ~/.ironpet/config.json, with its default.
section: Reference
order: 17
---

Most settings are in the Settings window (<kbd>⌘,</kbd> or right-click your pet → Settings…), where you can rename the pet, pick another from the pet gallery, change or turn off shortcuts, tune reminders and turn integrations on. Everything is stored in `~/.ironpet/config.json`, which you can also edit by hand or keep in your dotfiles. Changes apply within a couple of seconds.

List only the keys you want to change. Anything missing uses the default.

## Defaults

```json
{
  "pet": { "name": "Ghost", "sprite": "~/.ironpet/pet/spritesheet.png" },
  "hotkeys": {
    "chat": "cmd+opt+g",
    "captureWindow": "cmd+opt+shift+g",
    "captureRegion": "cmd+opt+ctrl+g",
    "voice": "cmd+opt+v",
    "meeting": "",
    "voiceMode": "ctrl+shift+v",
    "dictation": "ctrl+opt+space",
    "copyVersion": ""
  },
  "reminders": { "paused": false, "idleResetMinutes": 5, "snoozeMinutes": 10 },
  "automations": { "logRetentionDays": 14, "autoFix": true, "autoApprove": false, "autoApproveBubbles": true, "ownRunLimit": 50, "keptThreads": 50, "runTimeoutSeconds": 900 },
  "skills": { "autoUpdate": true },
  "tasks": { "meetingSuggestions": true, "meetingSuggestionBubbles": true, "inboxScan": false, "inboxScanMinutes": 30, "inboxScanScreen": false, "inboxScanBubbles": true },
  "jobs": { "maxRunning": 3, "permissionTimeoutMinutes": 10, "turnTimeoutMinutes": 60, "retentionDays": 30 },
  "welcomeBack": { "enabled": true },
  "window": { "autoHide": false, "appearance": "system" },
  "integrations": { "trackAgents": true, "shareMCPSignIns": false },
  "voice": { "enabled": false, "baseUrl": "http://localhost:8000/v1", "model": "mlx-community/parakeet-tdt-0.6b-v3", "holdToTalk": true },
  "speech": { "speakReplies": "automatic", "model": "mlx-community/Kokoro-82M-bf16", "voice": "am_puck", "speed": 1.0 },
  "voiceMode": { "silenceSeconds": 20, "endPauseSeconds": 2.5, "speakJobUpdates": true },
  "meetings": { "enabled": false, "lastApp": "", "summaryAgent": "claude", "summaryModel": null, "autoSummary": true, "offerToRecordCalls": true, "ignoredMicApps": [], "recogniseSpeakers": false, "transcriptCharacters": 300000 },
  "telegram": { "enabled": false, "allowedUsers": [] },
  "screenCapture": { "enabled": false, "ocr": false, "retentionDays": 30, "excludedApps": [] },
  "desktopControl": { "enabled": false },
  "memory": { "reflect": true, "reflectAgent": null, "reflectModel": null, "digestMinutes": 60, "learnFromScreen": false, "maxClaimsPerEntity": 30, "reflectMaxNotes": 8, "reflectMaxInputChars": 24000, "reflectTimeoutSeconds": 180, "recallBytesMe": 4000, "recallBytesProject": 6000, "recallBytesPeople": 2000, "noteMaxLength": 240 },
  "remote": { "enabled": false, "port": 47380, "address": "", "machineName": "" },
  "updates": { "checkAutomatically": true, "installAutomatically": true },
  "chat": { "background": "default", "pasteAttachmentChars": 4000, "pasteAttachmentLines": 60, "sessionRolloverMB": 50, "sessionRetentionDays": 14 },
  "openIn": "auto",
  "editors": [{ "name": "My IDE", "bundleId": "com.x.ide", "urlTemplate": "myide://open?path={cwd}" }]
}
```

`editors` is empty by default; the entry above is an example. `pet.sprite`, `chat.customImage`, `meetings.summaryModel`, `memory.reflectAgent` and `memory.reflectModel` have no value until you set one. A value outside a setting's range is clamped to the nearest end of it.

If the file doesn't parse, ironpet uses the defaults and shows the error at the bottom of Settings. Saving from Settings then first copies your file to `config.invalid.json`.

## Pet

`pet.name` is the pet's name (empty goes back to `Ghost`). `pet.sprite` is the path to a sprite sheet; unset, ironpet uses `~/.ironpet/pet/spritesheet.png` when it exists and the bundled Ghost otherwise. See [Pets](/docs/pets/).

## Shortcuts

Shortcuts (`hotkeys`) combine `cmd`, `opt`, `ctrl` and `shift` with a letter, digit, punctuation key, `space`, `return`, `tab`, `escape`, an arrow, `f1` to `f12`, or one of the ISO and JIS keys `section` (§), `yen`, `underscore`, `keypad-comma`, `eisu` and `kana`. Each needs at least one of `cmd`, `opt` or `ctrl`; function keys and `section` can stand alone. An empty string turns a shortcut off.

| Key | Default | Does |
| --- | --- | --- |
| `chat` | `cmd+opt+g` | Opens the ironpet window on Chat |
| `captureWindow` | `cmd+opt+shift+g` | Captures the front window into a chat. See [Screen help](/docs/screen/) |
| `captureRegion` | `cmd+opt+ctrl+g` | Captures a region you drag into a chat |
| `voice` | `cmd+opt+v` | Records a voice note. Only while voice notes are on. See [Voice notes](/docs/voice/#voice-notes) |
| `voiceMode` | `ctrl+shift+v` | Records one spoken message for the chat. Only while voice notes are on. The old default `cmd+opt+ctrl+v` moves to this one. See [Talking to the chat](/docs/voice/#talking-to-the-chat) |
| `dictation` | `ctrl+opt+space` | Dictates into the focused text field in any app. Also accepts `fn` for Fn hold-to-talk. Only while voice notes are on. See [Dictation in other apps](/docs/voice/#dictation-in-other-apps) |
| `meeting` | none | Starts or stops a meeting transcript. Only while meeting transcripts are on. See [Meetings](/docs/meetings/) |
| `copyVersion` | none | Copies the app version and commit to the clipboard |

## Chat

- **Chat background** (`chat.background`) is `"default"` (plain), one of `"dusk"`, `"paws"`, `"ghosts"`, `"chatter"`, `"leaves"`, or `"custom"` with `chat.customImage` naming a file in `~/.ironpet/backgrounds`. An unknown name, or `"custom"` without an image, falls back to `"default"`. It shows behind the ironpet window and the Settings window. Settings → General → Chat background sets all of this and copies a PNG or JPEG you choose into that folder.
- **Pasted text** (`chat.pasteAttachmentChars` and `chat.pasteAttachmentLines`, defaults 4000 and 60, ranges 500 to 100,000 characters and 10 to 2,000 lines): a paste over either limit becomes a `pasted-text.txt` attachment instead of staying in the input. Settings → General sets both.
- **Long chats** (`chat.sessionRolloverMB`, 1 to 10,000, default 50, and `chat.sessionRetentionDays`, 1 to 365, default 14): Claude Code keeps every session in one file that only grows, even after compaction. When the file of a chat's session passes `sessionRolloverMB` megabytes and the chat is idle (no turn, approval, form or queued message), ironpet asks the old session for a short summary, then starts the next message in a fresh agent session. That first message carries the memory notes, the summary, the last 10 messages and a pointer to `memory_search`. The chat stays one thread, with one line saying a fresh session started. Transcripts of the sessions a chat left are deleted `sessionRetentionDays` days after their last write. Agents other than Claude Code are not rolled over. A `session: "fork"` automation run deletes its own copy of the transcript when it finishes.

## Window

- **Appearance** (`window.appearance`) is `"system"`, `"light"` or `"dark"`. It applies to the pet, bubbles and windows. Settings → General.
- **Window auto-hide** (`window.autoHide`, off by default) hides the ironpet window on every section when another app becomes active, and shows it again, on the same section and at the same place, when ironpet is activated (pet click, shortcut, menu bar item). A window you closed with <kbd>Esc</kbd> or the close button stays closed. It doesn't hide while an ironpet sheet, alert or open panel is up, a file drag is over the chat, a screen capture is running, or a voice note is being recorded or transcribed. The voice shortcut shows a hidden window as before. A running chat turn carries on while the window is hidden. Settings → General → "Hide the window when another app is in front" sets it, and a change applies at once.

## Opening sessions

**Open sessions in** (`openIn`) is `"auto"`, which opens the app that started the agent (found by walking the agent's parent processes), or the bundle id of a fixed app such as `"dev.zed.Zed"`. The picker in Settings → General offers Cursor, VS Code, Zed, Band, Windsurf, Xcode, Finder, Orca, cmux, T3 Code, herdr, Claude and Codex when installed, plus your `editors` entries. Orca opens the session's worktree. cmux, T3 Code, herdr, Claude and Codex open the exact tab or thread of the session when the hook saw its id, and otherwise only bring the app forward.

Each `editors` entry has a `name`, a `bundleId` and an optional `urlTemplate`. Entries without a name or bundle id are ignored. In `urlTemplate`, `{cwd}` becomes the percent-encoded session folder and `{session}` the agent's session id. Without a template the folder is opened with the app.

## Reminders and automations

- **Reminders and alerts** live in `automations.json`; see [Automations](/docs/automations/). `config.json` keeps `reminders.idleResetMinutes` (default 5, at least 1), how long away from the keyboard resets every reminder, and `reminders.snoozeMinutes` (default 10, at least 1). Older `reminders.water`, `stretch`, `eyes` and `integrations.githubAlerts` keys still load, but are only read once, on the first launch with automations. `reminders.paused` still loads but is no longer read; pause reminders under right-click → Automations.
- **Automations** (`automations`):
  - `logRetentionDays` (1 to 365, default 14) is how long run logs are kept.
  - `autoFix` (on by default) asks the chat agent to fix a failing automation.
  - `autoApprove` (off by default) skips the Approve bubble for agent-written shell commands, scripts and prompts.
  - `autoApproveBubbles` (on by default) shows the "Auto-approved" bubble; off still records the notification.
  - `ownRunLimit` (1 to 500, default 50) is how many runs one automation's own thread takes before it starts fresh, for agents without a readable transcript.
  - `keptThreads` (1 to 500, default 50) is how many threads each automation keeps.
  - `runTimeoutSeconds` (60 to 7,200, default 900) is how long an automation's agent run may take.
- **Skills** (`skills.autoUpdate`, on by default): install missing skills and update installed ones at launch for the agents found on your Mac. Settings → General → Skills.

## Inbox and background jobs

- **Inbox** (`tasks`):
  - `meetingSuggestions` (on by default) offers a meeting's action items to the Inbox, and `meetingSuggestionBubbles` (on by default) shows the "From your meeting" bubble for them.
  - `inboxScan` (off by default) turns on the Inbox scan, `inboxScanMinutes` (5 to 1,440, default 30) is how often it runs, `inboxScanScreen` (off by default) also reads new screen captures, and `inboxScanBubbles` (on by default) shows the bubble for items it adds. See [Inbox](/docs/inbox/).
- **Background jobs** (`jobs`):
  - `maxRunning` (1 to 5, default 3) is how many run at once.
  - `permissionTimeoutMinutes` (1 to 1440, default 10) is how long a permission request from a job or an automation's own session waits before the agent gets its reject option.
  - `turnTimeoutMinutes` (1 to 1440, default 60) is how long one job's agent may run before ironpet stops it.
  - `retentionDays` (1 to 365, default 30) is how long finished jobs are kept.

  See [Background jobs](/docs/automations/#background-jobs).

## Welcome back

`welcomeBack.enabled` (on by default) shows the summary bubble when you return. How long counts as away is `reminders.idleResetMinutes`. See [Notifications](/docs/notifications/#welcome-back).

## Integrations

- `integrations.trackAgents` (on by default) turns agent watching on or off as a whole. Off removes ironpet's hooks from every agent's config and hides the Agents section on the Mac and the iPhone. See [Agents](/docs/agents/).
- Which agents are watched is stored in `integrations.cursorHooks`, `integrations.claudeHooks` and `integrations.hooks` (for the others, such as `{ "codex": true }`; the ids are `codex`, `gemini`, `copilot` and `pi`). Set them with the **Watch** switches in Settings → General → Watch sessions.
- `integrations.shareMCPSignIns` (off by default) copies your MCP sign-ins into each chat's folder. See [Chat](/docs/chat/#mcp-servers).
- **Telegram** (`telegram`) is covered in [Telegram](/docs/telegram/). The bot token is not in this file; it's stored in the Keychain.

## Updates

`updates.checkAutomatically` (on) asks GitHub once a day whether a newer release exists. `updates.installAutomatically` (on) downloads it in the background and installs it when no agent turn, voice note or meeting recording is running, or when you click the arrow badge on the pet. Both are in Settings → General → Updates, with **Check now**. A build from `scripts/install.sh` never updates. See [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md).

## Remote API

`remote.enabled` (off by default) turns on the listener for a paired iPhone.

- `port` defaults to 47380, from 1024 to 65535. Ports 47321 to 47340 aren't allowed; a port outside the range or in that block goes back to 47380.
- `address`: empty uses the first line of the Network list in Settings → Devices, Tailscale first. Otherwise an address from that list, an IPv4 address of this Mac, or the URL of your own HTTPS front such as `https://mac.tailnet.ts.net`. An older `remote.baseUrl` moves to `address` when the config loads.
- `machineName`: empty uses the name from System Settings.

Pair and revoke devices in Settings → Devices. See [iPhone](/docs/iphone/), [SPEC.md › Remote API](https://github.com/irtazahashmi/ironpet/blob/main/SPEC.md#remote-api) and [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md).

## Voice, screen and meetings

- **Voice** (`voice`) is covered in [Voice notes](/docs/voice/#voice-notes), **speech** (`speech`, including `speech.speakReplies` and `speech.speed`) in [Spoken replies](/docs/voice/#spoken-replies), and **spoken messages** (`voiceMode`, `hotkeys.voiceMode`) in [Talking to the chat](/docs/voice/#talking-to-the-chat). The API key is not in this file; it's stored in the Keychain. Older `speech.enabled` and `voiceMode.enabled` keys are ignored.
- **Screen capture** (`screenCapture`) and **desktop control** (`desktopControl`) are covered in [Screen help](/docs/screen/) and [Desktop control](/docs/desktop/). Both are off by default.
- **Meetings** (`meetings`, `hotkeys.meeting`) are covered in [Meetings](/docs/meetings/#settings). `meetings.ignoredMicApps` (empty by default) lists apps whose microphone use is never a call; it also stops them holding back spoken replies, and works with meetings off.

## Memory

- `reflect` (on by default) learns from chats.
- `reflectAgent` is `null` (or empty) for each chat's own agent, or an agent id to have only that agent's text read by it.
- `reflectModel` is `null` for the agent's cheap model (`haiku` for Claude Code, the default for the others), or a model id for the picked agent (ignored without one).
- `digestMinutes` (15 to 1,440, default 60) is how often the digest reads what is new.
- `learnFromScreen` (default `false`) also reads the text of new screen captures.
- `maxClaimsPerEntity` (10 to 200, default 30) is the page size above which the digest merges a page's oldest facts.
- `reflectMaxNotes` (1 to 20, default 8) caps the notes one pass saves.
- `reflectMaxInputChars` (2,000 to 200,000, default 24,000) is how much of a chat it reads.
- `reflectTimeoutSeconds` (30 to 1,800, default 180) is how long it waits for the agent.
- `recallBytesMe`, `recallBytesProject` and `recallBytesPeople` (500 to 50,000 bytes, defaults 4,000, 6,000 and 2,000) are how much of each goes into a chat's context.
- `noteMaxLength` (40 to 2,000 characters, default 240) is the longest note.

See [Memory](/docs/memory/).
