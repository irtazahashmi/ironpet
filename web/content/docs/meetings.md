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

### Recording a meeting in the room

To record people talking in the same room, choose **Record meeting in the room** from your pet's menu. It opens the same panel with **Room (microphone only)** preselected, and it stays the preselected choice next time. Room records only your microphone, like a voice recorder, so macOS is never asked for Screen & System Audio Recording and nothing is captured from the Mac. The consent notice still applies: tell everyone in the room.

A room meeting has one level row, **Room**, instead of Me and Them. Its chunks are `room-001.wav` and so on. With **Recognise speakers in meetings** on and the models downloaded, ironpet splits each chunk into speakers and names them like the Them track (`Speaker 1: …`, or a stored voice name). Without that, every line reads `Room: …`. A meeting never downloads the models. The transcript header names the app `Room`, and **Transcribe again** splits the room track into speakers too.

Room recording only starts when you start it.

With **Offer to record calls** on (the default), when another app holds the microphone for about 10 seconds, your pet asks whether to record it. Nothing records until you click **Record**.

## Files

Each meeting gets a folder in `~/.ironpet/meetings/<YYYY-MM-DD-HHmm>/` with:

- 16 kHz mono WAV chunks, `mic-001.wav` and `them-001.wav`, or `room-001.wav` for a room meeting
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

### Suggested title and speaker names

After the summary of a room recording or an imported file, the summary agent also proposes a title and a name for each voice that someone addresses or introduces by name in the transcript. A voice nobody names gets no suggestion, and a call meeting is not asked for either. Open the meeting in the Transcripts section. A **Suggestions** card shows the title and each name in a text field. Change the text if the agent got it wrong, then press **Use**. **Dismiss** drops them all.

- An accepted title is saved as `title.txt` in the meeting folder and replaces the date as the row heading on the Mac. The date moves to a line under it. The iPhone Meetings list shows the title too, with the date underneath.
- An accepted name replaces `Speaker 2` in every line of `transcript.md` and in `summary.md`, and stores the voice in the voice store when **Recognise speakers in meetings** is on and the voice has enough speech. This is the same step as naming a speaker right after a meeting. The voice data stays in memory, so after you quit ironpet the lines are still renamed but the voice is not stored.
- Suggestions wait in `suggestions.json` in the meeting folder until you accept or dismiss them. **Regenerate** replaces them and keeps a title you accepted.
- The instruction that asks for them is the prompt `meeting-suggestions` in Settings → Prompts.

### Import an audio file

**Import**, at the top of the Transcripts section, turns an m4a, mp3 or wav file into a meeting, for example a recording from your phone or a voice recorder. Pick the file in the dialog, drop it on the list, or open it with ironpet from Finder (**Open With**). The meeting gets a transcript, speakers and a summary from the same steps as a room recording: ironpet cuts the audio into `room-NNN.wav` chunks in the meeting folder, transcribes them with the server and model from Settings → Voice, names the voices when **Recognise speakers in meetings** is on and the models are downloaded, and runs the summary agent. The transcript header names the app `Imported audio`.

- The meeting's date is the file's creation date, or the time of the import when the file has none.
- A file over 4 hours or 1 GB, or in another format, is refused with a message that names the limit. No meeting is created.
- The audio goes to the transcription server from Settings → Voice, so tell the people on the recording. Video files are not imported.
- When the audio was saved but the transcript or summary failed, the meeting stays in the list. **Regenerate** tries again.
- One import or regeneration runs at a time. Several dropped files are imported one after another.
- From the iPhone, **Upload** in the Meetings screen or the share sheet sends a file to this Mac, which imports it the same way and refuses it with the same messages. See [the iPhone page](/docs/iphone/#what-the-phone-shows).

### Regenerate

**Regenerate**, the circular arrow next to **Ask**, rebuilds a past meeting from its saved audio, for example after you named a voice or changed the transcription model. It has two choices:

- **Transcript and summary**, the default click, transcribes every `mic-NNN.wav` and `them-NNN.wav` chunk again with the server and model from Settings → Voice, names the voices from the voice store when speaker recognition is on, and runs the summary agent and model from Settings → Meetings.
- **Summary only** skips the audio and summarises the current `transcript.md` again, which is what you want after naming a speaker.

Nothing in the folder changes until the whole run has succeeded. The files it replaces stay as `transcript.prev.md` and `summary.prev.md`. Only one generation is kept, so a second regeneration overwrites them. A failure leaves the old files and shows the error under the toolbar.

While it runs, the row and the page header show "Transcribing chunk 2 of 5", then "Summarising". One meeting is rebuilt at a time. The button is disabled, with the reason in its tooltip, while that meeting is recording or summarising, and when its audio is gone.

- A ticked action item (`- [x]`) stays ticked in the new summary when its text matches, ignoring case, spacing and a closing full stop.
- Inbox items are only added for action items the old summary didn't have.
- A name you typed for a voice that isn't in the voice store isn't kept, because the new transcript is built from the voice store and the audio.

## Room meetings from your calendar

With Suggest recording room meetings on (Settings → Meetings), Ghost reads your calendar on this Mac every 30 seconds. From 5 minutes before an event starts until 5 minutes after, an event that has a location and no call link gets one bubble: "Record in the room" or "Not now". "Record in the room" starts a room meeting named after the event, the same as choosing Room in the picker and pressing Start. Nothing starts without that press.

- A Zoom, Teams, Google Meet, Webex, Whereby, GoTo, BlueJeans, Chime, Jitsi, FaceTime, Skype or similar link in the location, the URL or the notes means the event is a call, so there is no room suggestion. The call offer for the microphone is unchanged.
- An event with no location, and an all-day event, gets no suggestion.
- Each event is suggested once. Dismissing or ignoring the bubble does not bring it back. No suggestion appears while a meeting is being set up, recorded or wrapped up.
- macOS asks for calendar access when you turn the setting on, and the setting stays off if you refuse. ironpet reads titles, times, locations, URLs and notes, changes nothing in your calendar, and keeps none of it.

## Settings

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Meeting transcripts | `meetings.enabled` | Default off |
| Summary agent | `meetings.summaryAgent` | An ACP agent id such as `"claude"` or `"cursor"`. Settings lists the installed agents |
| Summary model | `meetings.summaryModel` | A model id the agent reported in the chat. Unset uses the agent's default. Settings offers the models the agent listed the last time it ran in the chat |
| Summarize automatically | `meetings.autoSummary` | Default on. Off means no agent runs |
| Offer to record calls | `meetings.offerToRecordCalls` | Default on, and applies only with meetings on |
| Suggest recording room meetings | `meetings.suggestRoomRecordings` | Default off, and applies only with meetings on. Turning it on asks macOS for calendar access. See [Room meetings from your calendar](#room-meetings-from-your-calendar) |
| Never treat as a call | `meetings.ignoredMicApps` | Default empty. Bundle id prefixes, with at least two dot-separated parts such as `com.example.dictate`, of apps whose microphone use isn't a call, for example dictation apps. They get no call offer and don't hold back spoken replies. Siri, Apple dictation and Wispr Flow are always ignored. Works with meetings off |
| Recognise speakers in meetings | `meetings.recogniseSpeakers` | Default off. See [Recognising speakers](#recognising-speakers) |
| Transcript length | `meetings.transcriptCharacters` | Default 300,000, from 20,000 to 2,000,000. The summary reads the last this many characters. A longer transcript is cut at the start, and the summary says so |
| Start or stop shortcut | `hotkeys.meeting` | No default. Registered only while meetings are on |
| Last recorded app | `meetings.lastApp` | Written by ironpet: a bundle id, or `"all"` |

## Recognising speakers

With **Recognise speakers in meetings** on, ironpet splits the Them track into individual speakers on your Mac, after each chunk is transcribed. Lines read `Speaker 1: …` until you name the voice. The Me track is never split. A room meeting has no Me or Them, so its one Room track is split instead.

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
