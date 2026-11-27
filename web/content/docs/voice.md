---
title: Voice
description: Dictate to Ghost with Wispr Flow or voice notes, hear his replies, talk hands free, and dictate into any app.
section: Features
order: 7
---

You can talk to Ghost instead of typing, and he can answer out loud. Wispr Flow works with no setup. Voice notes, spoken replies, voice mode and dictation in other apps are all off by default and use a transcription server you choose, set up in **Settings → Voice**.

## Wispr Flow

Hold <kbd>fn</kbd> with [Wispr Flow](https://wisprflow.ai) while the chat is open. The dictation is sent automatically.

## Voice notes

ironpet ships and downloads no speech model. It records the microphone as a 16 kHz mono WAV and posts it to any server that speaks the OpenAI transcription API. With the feature off, the microphone is never opened, no permission is requested and nothing is sent.

Turn it on under **Settings → Voice → Talk to Ghost**, then fill in the **Server** section below it:

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Base URL | `voice.baseUrl` | Without `/audio/transcriptions` |
| Transcription model | `voice.model` | Sent as the `model` field |
| API key | none | Optional. Stored in the Keychain (`ironpet.voice`), never in `~/.ironpet` |
| Voice shortcut | `hotkeys.voice` | Default <kbd>⌥⌘V</kbd>. Registered only while voice notes are on |
| Dictation shortcut | `hotkeys.dictation` | Default <kbd>⌃⌥Space</kbd>, empty turns it off. See [Dictation in other apps](#dictation-in-other-apps) |
| Hold to talk | `voice.holdToTalk` | Default on: hold the shortcut to record and release to transcribe. Off: press once to start and again to stop |

**Test connection** sends a one-second tone and shows the server's answer or the error.

| Provider | Base URL | Model |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini-transcribe` |
| Groq | `https://api.groq.com/openai/v1` | `whisper-large-v3-turbo` |
| Local [mlx-audio](https://github.com/Blaizzy/mlx-audio) (Apple Silicon) | `http://localhost:8000/v1` | `mlx-community/parakeet-tdt-0.6b-v3` |

For the local option, start the server yourself. It needs no key:

```bash
uvx --from "mlx-audio[server]" mlx_audio.server
```

### Recording a voice note

Click the microphone button in the chat input, or use the voice shortcut. While recording, <kbd>Enter</kbd> stops and transcribes and <kbd>Esc</kbd> cancels. A note is cut off after 5 minutes. If the server is unreachable or answers with an error, the chat shows the error with a **Retry** button that sends the same recording again.

The transcript goes into the chat input for you to edit, or is sent right away when **Send voice notes automatically** is on in the chat's settings menu (on by default). Pasted, typed and Wispr Flow text is never sent automatically.

## Dictation in other apps

With voice notes on, press the dictation shortcut (<kbd>⌃⌥Space</kbd> by default) in any app, speak, and press it again (or press <kbd>Enter</kbd>) to type the transcript at the cursor. A small pill with a recording dot and a level meter shows while it records. <kbd>Esc</kbd> or the close button discards the recording.

To use Fn instead, click **Use Fn** next to the shortcut. Hold Fn, speak, and release to type. A tap shorter than 0.3 seconds starts recording and the next tap stops it. macOS asks for Input Monitoring only when you choose Fn. ironpet never consumes Fn, so Fn with other keys and the emoji picker keep working.

The text goes in through Accessibility. If the app ignores that, ironpet pastes it with <kbd>⌘V</kbd> and puts your earlier clipboard back. Password fields never get text. When no text field has focus, or Accessibility isn't allowed, the transcript stays on the clipboard and a notice says so. Dictation needs Microphone and Accessibility access.

## Spoken replies

Every reply has a speaker button below it (shown on hover) and a **Read Aloud** menu item, whether or not automatic reading is on. To have Ghost read each reply automatically, turn on **Settings → Voice → Ghost talks back**: pick a voice and press **Preview**, and the switch turns on once the preview plays. Spoken replies use the same server, base URL and key as voice notes, with their own model and voice. Voice notes don't have to be on.

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Read replies aloud automatically | `speech.enabled` | Default off. The speaker button works either way |
| Speech model | `speech.model` | Default `mlx-community/Kokoro-82M-bf16` |
| Voice | `speech.voice` | Default `am_puck` |
| Speed | `speech.speed` | Default `1.0`, from 0.5 to 2.0 |

Only the prose is read: code blocks, tables, bare links and emoji are skipped, and reading stops after about a minute. Replies to Telegram messages and automations aren't read automatically. Ghost stops on <kbd>Esc</kbd> in the chat, a new voice note, sending a message, or the speaker button. He doesn't read on his own during a call or while a meeting is recording.

The reply's text goes to the speech server. With a local server it stays on your Mac.

| Provider | Base URL | Speech model | Voices |
| --- | --- | --- | --- |
| Local mlx-audio with Kokoro (Apple Silicon) | `http://localhost:8000/v1` | `mlx-community/Kokoro-82M-bf16` | 54, such as `am_puck`, `af_heart`, `bf_emma` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini-tts` | `alloy`, `nova`, `onyx`, … |

Kokoro needs the `misaki` package, so start the local server with:

```bash
uvx --from "mlx-audio[server]" --with "misaki[en]" mlx_audio.server
```

The first spoken reply after the server starts downloads Kokoro (about 330 MB, once).

## Voice mode

Voice mode is a hands-free conversation with Ghost. Turn it on under **Settings → Voice → Conversation**; the switch turns on only after the server transcribes a test clip and speaks one line. Then press <kbd>⌃⌥⌘V</kbd> anywhere. A pill by Ghost says **Listening…**. Talk, stop, and Ghost answers out loud and listens again. Talking over him cuts him off.

The conversation ends when you say "bye" or "that's all", press <kbd>Esc</kbd> or the shortcut again, or say nothing for 20 seconds.

Ghost answers quick questions himself ("what's going on", "anything need me") and hands real work to a [background job](/docs/automations/#background-jobs), then tells you what he started. A job started by voice waits until Ghost has told you about it and 5 seconds more, so "cancel that" stops it before it does anything.

A spoken yes never approves anything: a job's Allow and Deny stay buttons. Before starting something that sends a message, email or comment to someone, Ghost reads it back and waits for you to say yes. Voice mode won't start during a call or a meeting recording.

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Voice mode | `voiceMode.enabled` | Default off |
| Shortcut | `hotkeys.voiceMode` | Default `cmd+opt+ctrl+v`, registered only while voice mode is on |
| Listen with | `voiceMode.listenWith` | `ironpet` (the microphone) or `wispr` (Wispr Flow's dictation is sent as soon as it lands) |
| Model | `voiceMode.model` | Empty uses the agent's fastest model, else the chat's |
| End after silence | `voiceMode.silenceSeconds` | Default 20, 5 to 120 |
| Close when idle | `voiceMode.idleShutdownMinutes` | Default 10, 1 to 120 |
| Speak job updates | `voiceMode.speakJobUpdates` | Default on |

Past voice conversations are in Chat's **Previous chats** menu, marked with a microphone.
