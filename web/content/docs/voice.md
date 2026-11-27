---
title: Voice
description: Dictate to Ghost with Wispr Flow or voice notes, hear his replies, talk to the chat, and dictate into any app.
section: Features
order: 7
---

You can talk to Ghost instead of typing, and he can answer out loud. Wispr Flow works with no setup. Voice notes, dictation in other apps and talking to the chat are off until you turn on voice notes, and they use a transcription server you choose, set up in **Settings → Voice**. Spoken replies start on **Automatic**, which reads a reply only after a message you said aloud, so no reply text goes to a speech server until you talk to the chat or press a reply's speaker button.

## Wispr Flow

Hold <kbd>fn</kbd> with [Wispr Flow](https://wisprflow.ai) while the chat is open. The dictation is sent automatically.

## Voice notes

Voice notes are off by default. ironpet ships and downloads no speech model. It records the microphone as a 16 kHz mono WAV and posts it to any server that speaks the OpenAI transcription API (`POST {baseUrl}/audio/transcriptions`, with `file`, `model` and `response_format=json`). With the feature off, the microphone is never opened, no permission is requested and nothing is sent.

Turn on **Voice notes** under **Settings → Voice → Talk to Ghost**, then fill in the **Server** section below it:

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Voice notes | `voice.enabled` | Default off |
| Base URL | `voice.baseUrl` | Default `http://localhost:8000/v1`. Without `/audio/transcriptions` |
| Transcription model | `voice.model` | Default `mlx-community/parakeet-tdt-0.6b-v3`. Sent as the `model` field |
| API key | none | Optional. Stored in the Keychain (`ironpet.voice`), never in `~/.ironpet` |
| Voice shortcut | `hotkeys.voice` | Default <kbd>⌥⌘V</kbd>. Registered only while voice notes are on |
| Dictation shortcut | `hotkeys.dictation` | Default <kbd>⌃⌥Space</kbd>, empty turns it off. Any key combination with ⌘, ⌥ or ⌃, a function key, <kbd>§</kbd> alone or with modifiers, or `fn` for Fn hold-to-talk. Registered only while voice notes are on. See [Dictation in other apps](#dictation-in-other-apps) |
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

To also hear [spoken replies](#spoken-replies) from the same local server, start it with the Kokoro command shown there instead.

### Recording a voice note

Click the microphone button in the chat input (click again to stop), or use the voice shortcut: hold and release, or press to start and press again to stop, depending on **Hold to talk**. The first recording makes macOS ask for microphone access.

While recording, a waveform with the elapsed time replaces the whole input, with only Stop and Cancel left. <kbd>Enter</kbd> stops and transcribes and <kbd>Esc</kbd> cancels. While transcribing, the input shows a spinner and Cancel. A note is cut off after 5 minutes. If the server is unreachable or answers with an error, the chat shows the error with a **Retry** button that sends the same recording again.

The transcript goes into the chat input for you to edit, or is sent right away when **Send voice notes automatically** is on in the chat's settings menu (on by default). Pasted, typed and Wispr Flow text is never sent automatically.

## Dictation in other apps

With voice notes on, press the dictation shortcut (<kbd>⌃⌥Space</kbd> by default) in any app, speak, and press it again (or press <kbd>Enter</kbd>) to type the transcript at the cursor. A small dark pill with a recording dot, a dotted level meter and a close button shows while it records, above the focused field or at the top of the screen, in your macOS accent colour. <kbd>Esc</kbd> or the close button discards the recording and types nothing.

Change or clear the shortcut in **Settings → Voice**. Besides the usual keys, the recorder accepts <kbd>§</kbd> (the ISO key left of 1) alone or with modifiers, and the JIS keys Yen, Underscore, Keypad Comma, Eisu and Kana with a modifier.

### Using Fn

To use Fn instead, click **Use Fn** next to the shortcut (`hotkeys.dictation` is then `fn`). Hold Fn, speak, and release to type the transcript. A tap shorter than 0.3 seconds starts recording and the next tap stops it. Fn pressed together with another key cancels a recording that press started.

macOS asks for Input Monitoring only when you choose Fn, and ironpet installs a listen-only event tap only while Fn is chosen. It never consumes Fn, so Fn with other keys and the emoji picker keep working. If a tap on the Globe key opens the emoji picker, turn the Globe key's own action off in System Settings → Keyboard.

### Where the text goes

The text goes in through Accessibility. If the app ignores that, ironpet pastes it with <kbd>⌘V</kbd> and puts your earlier clipboard back, unless you copied something else in the meantime. Password fields never get text. When no text field has focus, or Accessibility isn't allowed, the transcript stays on the clipboard and a notice says so.

Dictation uses the same transcription server as voice notes and needs Microphone and Accessibility access. It doesn't touch the chat's own voice note.

## Spoken replies

Ghost can answer out loud. A reply that is read aloud starts with a one or two sentence summary on its own first line. Ghost reads that line, and the full answer stays in the chat, links, lists and paths included. The agent writes the summary as part of the reply, so speech starts without a second model call, as soon as the first line is complete.

Every reply also has a speaker button below it (shown on hover) and a **Read Aloud** menu item that reads the whole reply, whatever **Speak replies** says.

Set it up under **Settings → Voice → Ghost talks back**: pick a voice and press **Preview**. Switching from Never to Automatic or Always takes effect only after the preview plays. Spoken replies use the server, base URL and key from [Voice notes](#voice-notes), with their own model (**Speech model** in the **Server** section) and voice (`POST {baseUrl}/audio/speech`). Voice notes don't have to be on.

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Speak replies | `speech.speakReplies` | `automatic` (default), `always` or `never`. Automatic reads the summary only after a message you said with the talk shortcut. Always reads it after every message you send from the chat. Never reads nothing on its own. The speaker button works in all three |
| Speech model | `speech.model` | Default `mlx-community/Kokoro-82M-bf16` |
| Voice | `speech.voice` | Default `am_puck`. Settings lists the model's voices when the server offers `/audio/voices` (mlx-audio does), and a text field otherwise |
| Speed | `speech.speed` | Default `1.0`, from 0.5 to 2.0. Sent with each speech request |

- **Upgrading.** Older config files have `speech.enabled` (read aloud) and `voiceMode.enabled` (voice mode). Both are ignored, and every file starts on Automatic whatever those switches were, so nothing is read after a typed message until you choose Always.
- **What is read.** Only the summary, never the full answer. A typed message after a spoken one isn't read in Automatic, and its prompt doesn't ask for a summary. Replies to Telegram messages and automations are never read. Code, tables, bare links and emoji are skipped in what is read. If the reply has no line break, the one line is read once the turn ends.
- **When he stops.** <kbd>Esc</kbd> in the chat, a new voice note, sending a message, pressing the talk shortcut, or the speaker button. A reply isn't read on its own during a call (any other app using the microphone) or while a meeting is recording. The speaker button still works then. Apps you list under **Never treat as a call** in [Meetings](/docs/meetings/#settings) don't count as a call.
- **Where the text goes.** The summary's text goes to the base URL above. With a local server it stays on your Mac.

| Provider | Base URL | Speech model | Voices |
| --- | --- | --- | --- |
| Local mlx-audio with Kokoro (Apple Silicon) | `http://localhost:8000/v1` | `mlx-community/Kokoro-82M-bf16` | 54, such as `am_puck`, `af_heart`, `bf_emma` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini-tts` | `alloy`, `nova`, `onyx`, … |

Kokoro needs the `misaki` package, which `mlx-audio[server]` doesn't install, so start the local server with:

```bash
uvx --from "mlx-audio[server]" --with "misaki[en]" mlx_audio.server
```

The same server still transcribes voice notes and meetings. The first spoken reply after the server starts downloads Kokoro (about 330 MB, once) and loads it, which takes a while. After that a sentence takes well under a second.

## Talking to the chat

Press <kbd>⌃⇧V</kbd> anywhere and talk. Ghost looks up, attentive, with a small pill by him that says **Listening…**. When you stop talking, or press the shortcut again, what you said is transcribed and sent to the chat as a message with a microphone badge. It lands in the same thread, history and agent session as the messages you type, so the agent sees the earlier turns as context. If **Speak replies** is Automatic or Always, the reply starts with a short summary that Ghost reads aloud while the full answer is written in the chat.

It records one message per press and doesn't keep listening afterwards. It needs voice notes on, because the same server transcribes it, and it goes to the chat of the active agent, as voice notes do.

<kbd>⌃⇧V</kbd> is Paste and Match Style in many Mac apps, and ironpet's global shortcut takes it over everywhere while voice notes are on. If that gets in your way, change or clear **Spoken message shortcut** under **Settings → Voice → Talk to the chat**, or set `hotkeys.voiceMode` to another shortcut, or to an empty string to turn it off.

| Setting | `config.json` key | Notes |
| --- | --- | --- |
| Spoken message shortcut | `hotkeys.voiceMode` | Default `ctrl+shift+v`, registered only while voice notes are on. Config files that still hold the old default `cmd+opt+ctrl+v` move to the new one |
| Stop after silence | `voiceMode.silenceSeconds` | Default 20, 5 to 120. Listening stops if you say nothing for this long |
| Speak job updates | `voiceMode.speakJobUpdates` | Default on |

- **The microphone** is open only while listening, with macOS voice processing on. <kbd>Esc</kbd> or the pill's button discards the message. Pressing the shortcut while Ghost is speaking stops him and starts listening.
- **Jobs.** When the chat starts a [background job](/docs/automations/#background-jobs) during a reply that is being read aloud, Ghost says when it's done, fails or needs your OK, unless Speak replies is Never, or you're on a call, recording a meeting or away.
- **What a spoken message can't do.** A spoken yes never approves anything: approvals stay buttons in an alert or a bubble. A spoken message gets the same permissions as a typed one.
- **When he stays quiet.** The shortcut won't start during a call (another app holding the microphone) or a meeting recording, and stops if one starts.
- **Old voice conversations.** Conversations saved before this change are still in Chat's **Previous chats** menu, marked with a microphone.
- **Removed.** The separate voice mode switch, its model, Wispr Flow listening and the front desk agent are gone. Wispr Flow still dictates into the chat input as before.
