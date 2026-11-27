---
title: Telegram
description: Chat with your pet from Telegram through a bot of your own.
section: Features
order: 15
---

You can send messages to your pet's chat from Telegram, through a bot you create. It's off by default. Turn it on in **Settings → Integrations**.

ironpet long-polls Telegram's Bot API (`api.telegram.org`) for your own bot, so there's no webhook and no public URL. Only messages from users you allow reach the chat.

## Setting it up

1. In Telegram, message @BotFather, send `/newbot` and copy the token.
2. In **Settings → Integrations**, paste the token, press **Save**, then **Test**. The token goes to the Keychain (`ironpet.telegram`), never to `~/.ironpet`.
3. Turn on **Chat from Telegram**.
4. Message your bot `/start`. A bubble next to your pet asks **Allow** or **Deny**. While nobody is allowed yet, that's the only way anyone can ask. You can also add a user id by hand in Settings.

Allowed users are kept in `telegram.allowedUsers` in `config.json`. An allowed user can start turns in your chat, so treat their account like your own and keep the list short.

## How it works

A message from an allowed user goes into the chat that's open on the Mac and doesn't change its session or folder. If the agent is busy, the message waits and runs when the current turn ends. The answer to a message sent from Telegram goes back to that Telegram chat, split into messages of at most 4096 characters. Turns you start on the Mac aren't sent to Telegram. `/status` shows the chat title and whether the agent is busy. Only private chats work.

### Files

A photo or document you send is downloaded to `~/.ironpet/telegram/files/<chat id>/` and attached to the message in the chat, like a file you attach on the Mac. The caption is the message text. Telegram lets bots download files up to 20 MB. A larger file gets a reply saying so, and nothing reaches the chat. The newest 50 downloads per chat are kept.

### Voice messages

With voice notes on (**Settings → Voice**), a voice message, audio file or video note is sent to your transcription server; see [Voice notes](/docs/voice/#voice-notes). Telegram gets the transcript first (`🎙 text`), and the chat gets it as the message text.

macOS can't decode OGG/Opus, so voice messages are sent to the server as OGG. Use a server that accepts it; OpenAI and Whisper-style servers do. With voice notes off, or when transcription fails, Telegram gets the error and nothing reaches the chat.

### Approvals

When a turn started from Telegram needs a tool approval, Telegram gets the same title and detail as the Mac, with **Approve** and **Reject** buttons. A tap applies the decision the way the Mac's **Allow** and **Deny** do, and the message is edited to show the outcome. If you answer on the Mac first, the message says so and a later tap does nothing. Only allowed users can press the buttons. The Mac offers no "Always", so there's no such button.

### Forms

When the agent asks a form in the chat, Telegram gets a header message and one message per question, whichever client started the turn.

- Select and yes/no questions have buttons. A multi-select question toggles options, then **Done**.
- Text and number questions, and the Other box, are answered by replying to the question's message.
- **Skip form** declines the form.

Whoever answers first wins. If you answer on the Mac, the Telegram messages say so and lose their buttons. If you answer in Telegram, the Mac shows the answered form.

## Connection trouble

A bad token, a lost connection or a second program polling the same bot shows in the status line in **Settings → Integrations**. Polling retries with a delay that doubles, up to 5 minutes.

Text sent to and from your bot passes through Telegram's servers.
