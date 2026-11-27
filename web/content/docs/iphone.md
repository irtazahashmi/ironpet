---
title: iPhone
description: Pair an iPhone to see Ghost, chat, answer approvals and check your Inbox away from the Mac.
section: Features
order: 14
---

A paired iPhone reaches the same ironpet state as the Mac: one chat, one Inbox, the same agents and alerts. You pair it in **Settings → Devices** on the Mac. The remote API that makes this work is off by default.

There's no public cloud involved. The phone talks only to your Mac, over your Wi-Fi or Tailscale.

## Pairing

1. Install **IronPet** from TestFlight.
2. On the Mac, open **Settings → Devices**, turn on the remote API, and leave the page open. It shows a pairing code as a QR code and a copyable `ironpet://` link. The code works once, for five minutes.
3. On the phone, scan the code or paste the link. Allow the device when Ghost asks on the Mac.

Revoke any device from the same Settings page.

## What the phone shows

The phone has five tabs: Pet (with Today), Chat, Inbox, Agents and More. More holds Alerts, Automations, Meetings, Screen and Settings, plus your [dashboards](/docs/using-ironpet/#dashboards) and Memory.

- **Chat.** Messages land in the chat that's open on the Mac and are marked "iPhone". The Mac doesn't read them aloud.
- **Approvals.** The phone can answer Allow / Deny and chat forms, so treat a paired, unlocked phone like your Mac.
- **Voice.** With voice notes on the Mac, the phone can stream dictation into the chat, and it can play spoken replies when you turn that on in the phone app.
- **Automations.** Automations created or changed from the phone always wait for **Approve** on the Mac.
- **Meetings.** The phone can read summaries and transcripts, after Face ID or your passcode. It can stop a recording but never start one, and never receives the audio.
- **Screen text.** Reading screen captures on the phone needs an extra per-device switch on the Mac (Settings → Devices → Screen text).

Meetings and screen capture can only be turned off from the phone, never on.

## Phone agent

More → Phone agent opens an agent that runs on the phone itself, so it works when the Mac is asleep. It calls Claude (the default) or OpenAI directly, with an API key you enter in its settings. The key stays in the phone's Keychain.

It can add and read Inbox items, read memory, read your calendar, add reminders, fetch public web pages and tell the date. An item it adds while the Mac is out of reach waits on the phone and goes to the Mac's Inbox when the Mac answers. Coding, repositories and the Mac's screen need the agent on the Mac. What you type to the phone agent goes to the provider you picked.

## Network and security

The remote API listens on port 47380 (`remote.port`) on the one network address you pick in Settings → Devices, with Tailscale listed first. Any device on that network can reach the port, though only a paired device with a valid token gets past it. On a public Wi-Fi, keep the remote API off.

The connection uses a self-signed certificate, and the QR code carries its fingerprint, so the phone accepts only your Mac. The full list of what a paired phone can read and change is in [SECURITY.md](https://github.com/irtazahashmi/ironpet/blob/main/SECURITY.md).
