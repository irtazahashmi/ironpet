---
title: Meetings
description: Record and transcribe meetings, get a summary with action items, and recognise who spoke.
section: Features
order: 13
---

Meeting transcripts record your microphone and one app's audio, transcribe them, and write a summary with decisions and action items. They're off by default. They reuse the transcription server from **Settings → Voice** (`voice.baseUrl`, `voice.model` and the key in the Keychain), so ironpet still ships no speech model; see [Voice notes](/docs/voice/#voice-notes).

Turn them on under **Settings → Meetings**. The switch turns on only after the voice server passes the same test as **Test connection**.

With the feature off there is no menu item, no shortcut and no panel, and macOS is never asked for microphone or screen access.

Recording people without their consent is illegal in many places. The first meeting shows a notice about consent, and the recording status always shows beside your pet.

## Recording a meeting

Choose **Start meeting transcript…** from your pet's menu, or press the meeting shortcut if you set one. A small panel asks which app to record. A running Zoom, Teams, Webex, Slack or FaceTime is preselected, then your last choice, then a running browser. **All system audio** is always offered, and ironpet's own sound is always left out. The first time, macOS asks for Microphone and Screen & System Audio Recording access.

While recording, a bubble next to your pet shows a recording dot, the elapsed time, a live level for Me (your microphone) and Them (the app), the last few transcript lines, and **Stop** and **Cancel**. Cancel asks first, then deletes the meeting folder. If you close the bubble (the × on hover), your pet shows a red **Recording** button until the meeting ends. Click it to show the bubble again.

With **Offer to record calls** on (the default), when another app holds the microphone for about 10 seconds, your pet asks whether to record it. Nothing records until you click **Record**.

## Files

Each meeting gets a folder in `~/.ironpet/meetings/<YYYY-MM-DD-HHmm>/` with:

- 16 kHz mono WAV chunks, `mic-001.wav`, `them-001.wav` and so on
- `transcript.md`
- `summary.md`

A chunk closes at the first silence after about 2 minutes, and is cut at 5 minutes. Each chunk is sent to the transcription server as soon as it closes, and `transcript.md` is rewritten after every chunk:

```text
# Meeting 2026-11-14 14:00 (Zoom)
[14:02:10] Me: Can we ship the fix today?
[14:02:15] Them: Yes, after the review.
```

ironpet asks the server for `response_format=verbose_json` to get timed segments (Whisper `segments`, Parakeet `sentences`). If the server rejects that with a 400, as OpenAI's `gpt-4o-*-transcribe` models do, ironpet retries once with `json`. If the server answers with only text, which is what mlx-audio does for Parakeet, each chunk becomes one line stamped with the chunk's start time.

The recordings are yours, so ironpet never deletes them. Remove a folder when you no longer need it.

### Server trouble

A chunk that fails to transcribe stays on disk and is retried with a growing delay while recording continues. The panel shows how many are waiting. A chunk that still fails when you stop gets a line like `[14:02:00–14:04:05] (not transcribed: <reason>)`. **Retry** in the panel tries it again.

## Summary

When the transcript is final, ironpet runs the summary agent and model from Settings and writes its answer to `summary.md`: a short summary, decisions, and open action items as a checklist. A "Meeting summary ready" bubble opens it. **Open in chat** starts a new chat with `transcript.md` and `summary.md` attached.

The summary agent only gets the meeting folder and can't change anything: ironpet refuses every permission request from it, and writes `summary.md` itself.

Action items marked `owner: Me` go to the [Inbox](/docs/inbox/#meetings), and one bubble says how many. Items owned by someone else stay in the summary.

## Past meetings

The Transcripts section of the ironpet window lists past meetings with their summary and transcript, **Ask** (with your pet's name), **Regenerate** and **Move to Trash**.

### Regenerate

**Regenerate**, the circular arrow next to **Ask**, rebuilds a past meeting from its saved audio, for example after you named a voice or changed the transcription model. It has two choices:

- **Transcript and summary**, the default click, transcribes every `mic-NNN.wav` and `them-NNN.wav` chunk again with the server and model from Settings → Voice, names the voices from the voice store when speaker recognition is on, and runs the summary agent and model from Settings → Meetings.
- **Summary only** skips the audio and summarises the current `transcript.md` again, which is what you want after naming a speaker.

Nothing in the folder changes until the whole run has succeeded. The files it replaces stay as `transcript.prev.md` and `summary.prev.md`. Only one generation is kept, so a second regeneration overwrites them. A failure leaves the old files and shows the error under the toolbar.

While it runs, the row and the page header show "Transcribing chunk 2 of 5", then "Summarising". One meeting is rebuilt at a time. The button is disabled, with the reason in its tooltip, while that meeting is recording or summarising, and when its audio is gone.

- A ticked action item (`- [x]`) stays ticked in the new summary when its text matches, ignoring case, spacing and a closing full stop.
- Inbox items are only added for action items the old summary didn't have.
- A name you typed for a voice that isn't in the voice store isn't kept, because the new transcript is built from the voice store and the audio.

## Settings

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Meeting transcripts | `meetings.enabled` | Default off |
| Summary agent | `meetings.summaryAgent` | An ACP agent id such as `"claude"` or `"cursor"`. Settings lists the installed agents |
| Summary model | `meetings.summaryModel` | A model id the agent reported in the chat. Unset uses the agent's default. Settings offers the models the agent listed the last time it ran in the chat |
| Summarize automatically | `meetings.autoSummary` | Default on. Off means no agent runs |
| Offer to record calls | `meetings.offerToRecordCalls` | Default on, and applies only with meetings on |
| Never treat as a call | `meetings.ignoredMicApps` | Default empty. Bundle id prefixes, with at least two dot-separated parts such as `com.example.dictate`, of apps whose microphone use isn't a call, for example dictation apps. They get no call offer and don't hold back spoken replies. Siri, Apple dictation and Wispr Flow are always ignored. Works with meetings off |
| Recognise speakers in meetings | `meetings.recogniseSpeakers` | Default off. See [Recognising speakers](#recognising-speakers) |
| Transcript length | `meetings.transcriptCharacters` | Default 300,000, from 20,000 to 2,000,000. The summary reads the last this many characters. A longer transcript is cut at the start, and the summary says so |
| Start or stop shortcut | `hotkeys.meeting` | No default. Registered only while meetings are on |
| Last recorded app | `meetings.lastApp` | Written by ironpet: a bundle id, or `"all"` |

## Recognising speakers

With **Recognise speakers in meetings** on, ironpet splits the Them track into individual speakers on your Mac, after each chunk is transcribed. Lines read `Speaker 1: …` until you name the voice. The Me track is never split.

### Models

The first time you turn the switch on, ironpet downloads about 21 MB of Core ML models from Hugging Face into `~/Library/Application Support/FluidAudio/Models` and compiles them. Settings shows the progress, then "Ready". Turning the switch off and on again doesn't download them again.

A meeting never downloads anything. When the models are missing, the meeting runs as it does with the switch off.

### Naming voices

When a meeting is done, a bubble says new voices were found, with a **Label speaker voices** button that opens Settings → Meetings. There, each unnamed voice that spoke for 3 seconds or more is listed with its talk time, a clip of up to 5 seconds, one transcript line and a name field. Closing the bubble keeps the list until the next meeting starts.

- **Ignore** and **Two people mixed** stop ironpet asking and keep the voice out of the store.
- Naming a voice rewrites `transcript.md`. The list then offers **Regenerate summary**, which runs the summary again with the new names. Nothing runs until you press it, and the old summary is kept as `summary.prev.md`.

### Next meetings

| Match with a stored voiceprint | Result |
| --- | --- |
| Cosine similarity 0.70 or more, and 0.10 ahead of the second best | The voice gets the name |
| 0.55 to 0.70 | ironpet suggests the name and asks you |
| Below 0.55 | It stays `Speaker N` |

These numbers are in `SpeakerThresholds` (`Meeting/SpeakerMatcher.swift`) and come from one measured meeting.

### Voiceprints

The voice store keeps, per named person, one centroid of 256 numbers, their name, their seconds of speech and the number of meetings they were in. No audio is stored. It lives in `~/Library/Application Support/IronPet/voices.enc`, AES-GCM encrypted with a key in the Keychain item `ironpet.voiceprints`. A voice is added only when you name it and it has 10 seconds of speech or more.

- **Forget this voice** and **Forget all voices** in Settings delete entries at once.
- **Rename** in Settings changes a voice's name for later meetings, and rewrites it in the transcript labels and summaries of the past meetings where that voice spoke. A meeting where the name only appears in spoken text is left alone.

Voiceprints are biometric data about people who haven't consented, so tell them.

### Credits

- [FluidAudio](https://github.com/FluidInference/FluidAudio), Apache-2.0, runs speaker diarization on your Mac.
- The diarization models FluidAudio downloads on first use are the pyannote speaker-diarization community-1 pipeline and WeSpeaker embeddings, converted to Core ML by FluidInference ([speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)), CC-BY-4.0.
