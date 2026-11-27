---
title: Meetings
description: Record and transcribe meetings, get a summary with action items, and recognise who spoke.
section: Features
order: 13
---

Meeting transcripts record your microphone and one app's audio, transcribe them with the server from Settings → Voice, and write a summary with decisions and action items. They're off by default. Turn them on under **Settings → Meetings**; the switch turns on only after the voice server passes the same test as **Test connection**.

With the feature off there is no menu item, no shortcut and no panel, and macOS is never asked for microphone or screen access.

Recording people without their consent is illegal in many places. The first meeting shows a notice about consent, and the recording status always shows beside Ghost.

## Recording a meeting

Choose **Start meeting transcript…** from Ghost's menu, or press the meeting shortcut if you set one. A small panel asks which app to record. A running Zoom, Teams, Webex, Slack or FaceTime is preselected, then your last choice, then a running browser. **All system audio** is always offered, and ironpet's own sound is always left out. The first time, macOS asks for Microphone and Screen & System Audio Recording access.

While recording, a bubble next to Ghost shows the elapsed time, a live level for Me (your microphone) and Them (the app), the last few transcript lines, and **Stop** and **Cancel**. Cancel asks first, then deletes the recording. If you close the bubble, Ghost shows a red **Recording** button until the meeting ends.

With **Offer to record calls** on (the default), when another app holds the microphone for about 10 seconds, Ghost asks whether to record it. Nothing records until you click **Record**.

## Files

Each meeting gets a folder in `~/.ironpet/meetings/<YYYY-MM-DD-HHmm>/` with WAV audio chunks, `transcript.md` and `summary.md`. Each chunk is sent to the transcription server as soon as it closes, and the transcript is rewritten after every chunk:

```text
# Meeting 2026-11-14 14:00 (Zoom)
[14:02:10] Me: Can we ship the fix today?
[14:02:15] Them: Yes, after the review.
```

The recordings are yours, so ironpet never deletes them. Remove a folder when you no longer need it.

A chunk that fails to transcribe stays on disk and is retried while recording continues. **Retry** in the panel tries again after you stop.

## Summary

When the transcript is final, ironpet runs the summary agent and writes `summary.md`: a short summary, decisions, and open action items as a checklist. A "Meeting summary ready" bubble opens it. **Open in chat** starts a new chat with the transcript and summary attached. Action items marked as yours go to the [Inbox](/docs/inbox/).

The summary agent can't change anything: ironpet refuses every permission request from it.

## Past meetings

The Transcripts section of the ironpet window lists past meetings with their summary and transcript, **Ask Ghost**, **Regenerate** and **Move to Trash**.

**Regenerate** rebuilds a meeting from its saved audio, for example after you named a voice or changed the transcription model. **Summary only** skips the audio and summarises the current transcript again. The files it replaces stay as `transcript.prev.md` and `summary.prev.md`.

## Settings

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Meeting transcripts | `meetings.enabled` | Default off |
| Summary agent | `meetings.summaryAgent` | An ACP agent id such as `"claude"` or `"cursor"` |
| Summary model | `meetings.summaryModel` | Unset uses the agent's default |
| Summarize automatically | `meetings.autoSummary` | Default on. Off means no agent runs |
| Offer to record calls | `meetings.offerToRecordCalls` | Default on |
| Never treat as a call | `meetings.ignoredMicApps` | Default empty. Bundle id prefixes of apps whose microphone use is not a call, such as dictation apps. Siri, Apple dictation and Wispr Flow are always ignored |
| Recognise speakers in meetings | `meetings.recogniseSpeakers` | Default off |
| Transcript length | `meetings.transcriptCharacters` | Default 300,000, from 20,000 to 2,000,000. The summary reads the last this many characters |
| Start or stop shortcut | `hotkeys.meeting` | No default. Registered only while meetings are on |

## Recognising speakers

With **Recognise speakers in meetings** on, ironpet splits the Them track into individual speakers on your Mac. Lines read `Speaker 1: …` until you name the voice. The Me track is never split.

- **Models.** The first time you turn it on, ironpet downloads about 21 MB of models from Hugging Face. A meeting itself never downloads anything.
- **Naming voices.** When a meeting is done, a bubble offers **Label speaker voices**, which opens Settings → Meetings with each unnamed voice, a short clip and a name field. Naming a voice rewrites the transcript, and **Regenerate summary** runs the summary again with the new names.
- **Next meetings.** A voice that clearly matches a stored voice gets its name. A close match is suggested and you're asked. Otherwise it stays `Speaker N`.
- **Voiceprints.** One voiceprint per named person, with no audio, is kept encrypted in `~/Library/Application Support/IronPet/voices.enc`, with the key in the Keychain. **Forget this voice** and **Forget all voices** in Settings delete entries at once.

Voiceprints are biometric data about people who haven't consented, so tell them.
