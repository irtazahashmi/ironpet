---
title: Telegram
description: Chat with Ghost from Telegram through a bot of your own.
section: Features
order: 15
---

You can send messages to Ghost's chat from Telegram, through a bot you create. It's off by default. Turn it on in **Settings → Integrations**.

ironpet long-polls Telegram's Bot API for your own bot, so there's no webhook and no public URL. Only messages from users you allow reach the chat.

## Setting it up

1. In Telegram, message @BotFather, send `/newbot` and copy the token.
2. In **Settings → Integrations**, paste the token, press **Save**, then **Test**. The token goes to the Keychain (`ironpet.telegram`), never to `~/.ironpet`.
3. Turn on **Chat from Telegram**.
4. Message your bot `/start`. A bubble next to Ghost asks **Allow** or **Deny**. While nobody is allowed yet, that's the only way anyone can ask. You can also add a user id by hand in Settings.

Allowed users are kept in `telegram.allowedUsers` in `config.json`. An allowed user can start turns in your chat, so treat their account like your own and keep the list short.

## How it works

A message from an allowed user goes into the chat that's open on the Mac and doesn't change its session or folder. If the agent is busy, the message waits until the current turn ends. The answer goes back to the Telegram chat, split into messages of at most 4096 characters. Turns you start on the Mac aren't sent to Telegram. `/status` shows the chat title and whether the agent is busy. Only private chats work.

- **Files.** A photo or document you send is attached to the message in the chat. The caption is the message text. Telegram lets bots download files up to 20 MB.
- **Voice messages.** With voice notes on (Settings → Voice), a voice message is sent to your transcription server. Telegram gets the transcript first, and the chat gets it as the message text. Use a server that accepts OGG audio; OpenAI and Whisper-style servers do.
- **Approvals.** When a turn started from Telegram needs a tool approval, Telegram gets **Approve** and **Reject** buttons. If you answer on the Mac first, the message says so.
- **Forms.** When the agent asks a form, Telegram gets one message per question, with buttons where possible. Whoever answers first, on the Mac or in Telegram, wins.

Text sent to and from your bot passes through Telegram's servers.
