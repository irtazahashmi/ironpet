---
title: Configuration
description: Every key in ~/.ironpet/config.json, with its default.
section: Reference
order: 17
---

Most settings are in the Settings window (<kbd>⌘,</kbd> or right-click Ghost → Settings…), where you can rename the pet, pick another pet, change or turn off shortcuts, tune reminders and turn integrations on. Everything is stored in `~/.ironpet/config.json`, which you can also edit by hand or keep in your dotfiles. Changes apply within a couple of seconds.

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
    "voiceMode": "cmd+opt+ctrl+v",
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
  "speech": { "enabled": false, "model": "mlx-community/Kokoro-82M-bf16", "voice": "am_puck", "speed": 1.0 },
  "voiceMode": { "enabled": false, "listenWith": "ironpet", "model": "", "silenceSeconds": 20, "speakJobUpdates": true, "idleShutdownMinutes": 10, "fastModelWords": ["haiku", "flash", "mini", "fast", "lite"] },
  "meetings": { "enabled": false, "lastApp": "", "summaryAgent": "claude", "summaryModel": null, "autoSummary": true, "offerToRecordCalls": true, "recogniseSpeakers": false, "transcriptCharacters": 300000 },
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

If the file doesn't parse, ironpet uses the defaults and shows the error at the bottom of Settings. Saving from Settings then first copies your file to `config.invalid.json`.

## Shortcuts

Shortcuts (`hotkeys`) combine `cmd`, `opt`, `ctrl` and `shift` with a letter, digit, `space`, an arrow, or `f1` to `f12`. Each needs at least one of `cmd`, `opt` or `ctrl`; function keys can stand alone. An empty string turns a shortcut off.

The dictation shortcut, `hotkeys.dictation`, defaults to <kbd>⌃⌥Space</kbd>. It also accepts `fn` for Fn hold-to-talk. See [Voice](/docs/voice/#dictation-in-other-apps).

## Chat

- **Chat background** (`chat.background`) is `"default"` (plain), one of `"dusk"`, `"paws"`, `"ghosts"`, `"chatter"`, `"leaves"`, or `"custom"` with `chat.customImage` naming a file in `~/.ironpet/backgrounds`. It shows behind the ironpet window and the Settings window. Settings → General → Chat background sets all of this and copies a PNG or JPEG you choose into that folder.
- **Pasted text** (`chat.pasteAttachmentChars` and `chat.pasteAttachmentLines`, defaults 4000 and 60): a paste over either limit becomes a `pasted-text.txt` attachment instead of staying in the input. Settings → General sets both.
- **Long chats** (`chat.sessionRolloverMB` and `chat.sessionRetentionDays`, defaults 50 and 14): when the file of a Claude Code chat's session passes `sessionRolloverMB` megabytes and the chat is idle, ironpet asks the old session for a short summary and starts the next message in a fresh agent session. Transcripts of the sessions a chat left are deleted `sessionRetentionDays` days after their last write. Agents other than Claude Code are not rolled over.

## Window

- **Appearance** (`window.appearance`) is `"system"`, `"light"` or `"dark"`. It applies to the pet, bubbles and windows. Settings → General.
- **Window auto-hide** (`window.autoHide`, off by default) hides the ironpet window when another app becomes active, and shows it again on the same section when ironpet is activated. A window you closed stays closed. A running chat turn carries on while the window is hidden. Settings → General → "Hide the window when another app is in front".

## Opening sessions

**Open sessions in** (`openIn`) is `"auto"`, which opens the app that started the agent, or the bundle id of a fixed app such as `"dev.zed.Zed"`. The picker offers Cursor, VS Code, Zed, Band, Windsurf, Xcode, Finder, Orca, cmux, T3 Code, herdr, Claude and Codex when installed, plus your `editors` entries.

In an `editors` entry's `urlTemplate`, `{cwd}` becomes the percent-encoded session folder and `{session}` the agent's session id. Without a template the folder is opened with the app.

## Reminders and automations

- **Reminders and alerts** live in `automations.json`; see [Automations](/docs/automations/). `config.json` keeps `reminders.idleResetMinutes` and `reminders.snoozeMinutes`. Older `reminders.water`, `stretch`, `eyes` and `integrations.githubAlerts` keys still load, but are only read once, on the first launch with automations.
- **Automations** (`automations`):
  - `logRetentionDays` (default 14) is how long run logs are kept.
  - `autoFix` (on by default) asks the chat agent to fix a failing automation.
  - `autoApprove` (off by default) skips the Approve bubble for agent-written shell commands, scripts and prompts.
  - `autoApproveBubbles` (on by default) shows the "Auto-approved" bubble; off still records the notification.
  - `ownRunLimit` (1 to 500, default 50) is how many runs one automation's own thread takes before it starts fresh, for agents without a readable transcript.
  - `keptThreads` (1 to 500, default 50) is how many threads each automation keeps.
  - `runTimeoutSeconds` (60 to 7,200, default 900) is how long an automation's agent run may take.
- **Skills** (`skills.autoUpdate`, on by default): install missing skills and update installed ones at launch for the agents found on your Mac. Settings → General → Skills.

## Inbox and background jobs

- **Inbox** (`tasks`): `meetingSuggestions` adds a meeting's action items to the Inbox, and `meetingSuggestionBubbles` (on by default) shows the bubble for them. `inboxScan`, `inboxScanMinutes`, `inboxScanScreen` and `inboxScanBubbles` set the Inbox scan. See [Inbox](/docs/inbox/).
- **Background jobs** (`jobs`):
  - `maxRunning` (1 to 5, default 3) is how many run at once.
  - `permissionTimeoutMinutes` (1 to 1440, default 10) is how long a permission request from a job or an automation's own session waits before the agent gets its reject option.
  - `turnTimeoutMinutes` (1 to 1440, default 60) is how long one job's agent may run before ironpet stops it.
  - `retentionDays` (1 to 365, default 30) is how long finished jobs are kept.

## Welcome back

`welcomeBack.enabled` shows the summary bubble when you return. How long counts as away is `reminders.idleResetMinutes`. See [Notifications](/docs/notifications/#welcome-back).

## Integrations

- `integrations.trackAgents` turns agent watching on or off as a whole. See [Agents](/docs/agents/).
- `integrations.shareMCPSignIns` (off by default) copies your MCP sign-ins into each chat's folder. See [Chat](/docs/chat/#mcp-servers).
- **Telegram** (`telegram`) is covered in [Telegram](/docs/telegram/). The bot token is not in this file; it's stored in the Keychain.

## Updates

`updates.checkAutomatically` (on) asks GitHub once a day whether a newer release exists. `updates.installAutomatically` (on) downloads it in the background and installs it when no agent turn, voice note or meeting recording is running, or when you click the arrow badge on the pet. Both are in Settings → General → Updates, with **Check now**. A build from `scripts/install.sh` never updates.

## Remote API

`remote.enabled` (off by default) turns on the listener for a paired iPhone.

- `port` defaults to 47380. Ports 47321 to 47340 aren't allowed.
- `address`: empty uses the first line of the Network list in Settings → Devices, Tailscale first. Otherwise an address from that list, an IPv4 address of this Mac, or the URL of your own HTTPS front such as `https://mac.tailnet.ts.net`.
- `machineName`: empty uses the name from System Settings.

Pair and revoke devices in Settings → Devices. See [iPhone](/docs/iphone/).

## Voice, screen and meetings

- **Voice** (`voice`) is covered in [Voice notes](/docs/voice/#voice-notes), **speech** (`speech`) in [Spoken replies](/docs/voice/#spoken-replies), and **voice mode** (`voiceMode`) in [Voice mode](/docs/voice/#voice-mode). The API key is not in this file; it's stored in the Keychain.
- **Screen capture** (`screenCapture`) and **desktop control** (`desktopControl`) are covered in [Screen help](/docs/screen/). Both are off by default.
- **Meetings** (`meetings`, `hotkeys.meeting`) are covered in [Meetings](/docs/meetings/#settings).

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
