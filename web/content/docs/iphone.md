---
title: iPhone
description: Pair an iPhone to see your pet, chat, answer approvals and check your Inbox away from the Mac.
section: Features
order: 14
---

A paired iPhone reaches the same ironpet state as the Mac: one chat, one Inbox, the same agents and alerts. You pair it in **Settings → Devices** on the Mac. The remote API that makes this work is off by default.

There's no public cloud involved. The phone talks only to your Mac, over your Wi-Fi or Tailscale.

## Pairing

1. Install **IronPet** from TestFlight (bundle id `dev.ironpet.app`).
2. On the Mac, open **Settings → Devices**, turn on the remote API, and leave the page open. It shows a pairing code as a QR code and a copyable `ironpet://` link. The code works once, for five minutes.
3. On the phone, scan the code or paste the link. Allow the device when your pet asks on the Mac.

Revoke any device from the same Settings page.

## What the phone shows

The phone has five tabs: Pet (with Today), Chat, Inbox, Agents and More. More holds Alerts, Automations, Meetings, Screen and Settings, plus your [dashboards](/docs/dashboards/#on-the-iphone) and [Memory](/docs/memory/#the-memory-section).

- **Chat.** Messages land in the chat that's open on the Mac and are marked "iPhone". The Mac doesn't read them aloud.
- **Approvals.** The phone can answer Allow / Deny and chat forms, so treat a paired, unlocked phone like your Mac.
- **Voice.** With [voice notes](/docs/voice/#voice-notes) on the Mac, the phone can stream dictation into the chat, and it can play [spoken replies](/docs/voice/#spoken-replies) on the phone when you turn that on in the phone app.
- **Voice mode.** The waveform button next to the mic button starts voice mode. The phone listens, decides on the phone when you stopped talking, and sends the message to the primary chat with no second tap. A pause of 2.5 seconds after you speak ends the message. Voice mode stays on until you tap the button again: 20 seconds of silence only ends that turn and listening starts again, and so does a sent message once its reply is read. With spoken replies on, the phone reads only the first line of the reply, a short summary the agent writes for it, and the full answer stays in the chat. A message you type is read in full as before. Tapping the button sends nothing partial. These are the same defaults as the Mac's [spoken messages](/docs/voice/); the phone does not read your Mac's `voiceMode` settings yet.
- **Action button and lock screen.** On iOS 18 and later, Shortcuts offers **Start voice mode**. Set it on the Action button (Settings → Action Button → Shortcut) or add it to the lock screen controls. Pressing it starts listening without unlocking the phone, and listening and the spoken summary continue while the screen is locked or another app is open. It needs the app to be paired with your Mac. iOS 17 has no shortcut.
- **Inbox.** The Inbox tab shows the same list as the Mac. **Done** and **Remove** work on either. When the Mac runs an older version that doesn't serve the Inbox, the tab is empty instead of showing an error.
- **Automations.** Automations created or changed from the phone always wait for **Approve** on the Mac, even with auto-approve on.
- **Meetings.** The phone can read summaries and transcripts, after Face ID or your passcode. It can stop a recording but never start one, and never receives the audio. **Upload** in the top left sends an m4a, mp3 or wav file to the Mac, which imports it as a [meeting](/docs/meetings/#import-an-audio-file). You can also pick **IronPet** in the share sheet of Voice Memos, Files or another app. The file waits on the phone until the Mac is reachable, continues where it stopped when the connection drops, and the phone deletes its copy only after the Mac has the whole file. Sending happens while the app is open. The limits are the Mac's: 4 hours and 1 GB.
- **Screen text.** Reading screen captures on the phone needs an extra per-device switch on the Mac (**Settings → Devices → Screen text**).
- **Records.** Tapping a record id in chat, such as `meeting_9f3c1e`, opens that record's details.

Meetings and screen capture can only be turned off from the phone, never on.

## Phone agent

**More → Phone agent** opens an agent that runs on the phone itself, so it works when the Mac is asleep. It calls Claude (the default, `claude-sonnet-5-5`) or OpenAI directly, with an API key you enter in its settings. The key stays in the phone's Keychain.

It can add and read Inbox items, read memory, read your calendar, add reminders, fetch public web pages and tell the date. An item it adds while the Mac is out of reach waits on the phone and goes to the Mac's Inbox when the Mac answers. Coding, repositories and the Mac's screen need the agent on the Mac, and the phone agent says so. What you type to the phone agent goes to the provider you picked.

Once a key is set, the phone agent appears in the Mac's agent list (`agents_list`) as an agent of that device, with no pet and no chat on the Mac. Details are in [SPEC.md](https://github.com/irtazahashmi/ironpet/blob/main/SPEC.md#phone-agent).

## Network and security

| Setting | Key | Notes |
| --- | --- | --- |
| Remote API | `remote.enabled` | Default off |
| Port | `remote.port` | Default 47380. Ports 47321 to 47340 can't be used |
| Address | `remote.address` | Empty uses the first line of the Network list in **Settings → Devices**, with Tailscale first. Otherwise an address from that list, an IPv4 address of this Mac, or the URL of your own HTTPS front, such as `https://mac.tailnet.ts.net` |
| Machine name | `remote.machineName` | Empty uses the name from System Settings |

The remote API listens only on the address you pick. Any device on that network can reach the port, though only a paired device with a valid token gets past it. On a public Wi-Fi, keep the remote API off.

The connection uses a self-signed certificate, and the QR code carries its fingerprint, so the phone accepts only your Mac. The Mac keeps its remote API identity key, and files a paired phone uploaded, in `~/.ironpet/remote/`.

Routes, details and risks are in [SPEC.md › Remote API](https://github.com/irtazahashmi/ironpet/blob/main/SPEC.md#remote-api), [SPEC.md › iOS app](https://github.com/irtazahashmi/ironpet/blob/main/SPEC.md#ios-app) and [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md), which lists everything a paired phone can read and change.
