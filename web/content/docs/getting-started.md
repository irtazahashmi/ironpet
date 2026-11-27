---
title: Getting started
description: Install ironpet, run it the first time, and grant the permissions it asks for.
section: Basics
order: 1
---

ironpet puts Ghost, a small direwolf in a Night's Watch cloak, on your Mac desktop. He watches your coding agents, asks you before they run commands, and opens a chat when you click him. This page covers what you need, how to install it, and what happens on first launch.

## Requirements

- macOS 14 or later, on Apple Silicon or Intel.
- At least one agent CLI that speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP), installed and signed in. `cursor-agent`, `gemini`, `opencode` and many more run as they are. `claude`, `codex` and `pi` run through small adapters bundled in the app, which need Node 22 or newer on your `PATH`. Without Node, ironpet offers a one-time Bun download and asks before making it.
- Optional: iTerm2 and [Wispr Flow](https://wisprflow.ai).

To build from source you also need:

- Xcode command line tools (Swift 5.10 or newer). With the macOS 27 SDK, use full Xcode instead, selected with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, because SwiftUI's macros ship only with Xcode.
- [Bun](https://bun.sh) and npm, which bundle the chat adapters.

## Install

There are three ways to install ironpet. The download and Homebrew builds are for Apple Silicon only (the release notes say so). On an Intel Mac, build from source.

### Download the DMG (Apple Silicon)

Download `IronPet-<version>.dmg` from the [Releases](https://github.com/irtazahashmi/ironpet/releases) page, open it and drag IronPet to Applications. The download needs the same [requirements](#requirements) as a source build, except Bun, npm and the command line tools. You can check the download against its checksum file:

```bash
shasum -a 256 -c IronPet-<version>.dmg.sha256
```

A build named `-unsigned` is not signed by a developer, so macOS blocks its first launch. On macOS 15 or later, try to open it once, then click **Open Anyway** in System Settings → Privacy & Security. On macOS 14, right-click IronPet and choose Open. You can also run:

```bash
xattr -dr com.apple.quarantine /Applications/IronPet.app
```

### Homebrew (Apple Silicon)

Homebrew installs the same notarized release:

```bash
brew install --cask irtazahashmi/ironpet/ironpet
```

To uninstall, run `brew uninstall --cask ironpet`, or add `--zap` to delete its preferences too. See the [tap](https://github.com/irtazahashmi/homebrew-ironpet) for details.

### Build from source (Apple Silicon or Intel)

```bash
git clone https://github.com/irtazahashmi/ironpet.git
cd ironpet
./scripts/install.sh
```

`install.sh` checks the requirements and tells you how to fix anything that's missing. It builds the app, installs it to `/Applications/IronPet.app` and starts it. The first time, it also creates a local self-signed `ironpet-dev` code signing identity so macOS keeps Screen Recording and Automation permissions across rebuilds. macOS may ask for your login password to trust it. Run the script again any time to update.

### Switching from a source build to a release build

macOS ties Screen Recording, Accessibility, Automation and Microphone permissions to the app's signature. If you used `install.sh` before, a release build asks for them again once. macOS may also ask for your login password once so the new build can read its Keychain items. An old IronPet entry under Accessibility may show as ticked but not work: remove it and add IronPet again.

## First launch

On first launch a welcome window asks what Ghost may do:

- **Track coding agents** (on by default). Ghost watches the agents it finds on your Mac. ironpet merges a hook into each agent's own config, for example `~/.cursor/hooks.json` and `~/.claude/settings.json`, and backs up the original next to it as `*.ironpet-backup`. Codex also needs you to trust the hooks once in its `/hooks` screen.
- **Launch at login.**
- **Break reminders.**
- **GitHub alerts**, which need the `gh` CLI, signed in.

Nothing outside `~/.ironpet` changes until you press **Start**, and you can change every choice later in Settings.

## Optional setup

- **MCP servers.** Ghost's chat can use the MCP servers you have in Cursor (`~/.cursor/mcp.json`). To sign in to them once instead of in every project, turn on right-click → Integrations → **Share MCP sign-ins across folders**. See [Chat](/docs/chat/#mcp-servers).
- **GitHub alerts.** If you didn't tick them in the welcome window, ask your agent for them under ironpet window → Automations → **New automation…**. They need the `gh` CLI, signed in. See [Alerts](/docs/alerts/#github-alerts).
- **Sentry alerts.** Run `./scripts/configure_sentry.sh` from the repository. See [Alerts](/docs/alerts/#sentry-alerts).

## Bubbles and macOS notifications

Ghost speaks in bubbles beside him instead of macOS notifications. Approvals stay until you answer, reminders stay for 3 minutes, and everything else fades after 15 to 45 seconds, but not while the pointer is over them.

To get macOS notifications as well, turn on right-click → **Also show macOS notifications**. Then set ironpet's notification style to **Alerts** in System Settings → Notifications, so the Allow and Deny buttons stay on screen. See [Notifications](/docs/notifications/).

## Permissions

macOS asks for these permissions as you use the features, not all at once:

| Permission | Needed for |
| --- | --- |
| Notifications | Only with **Also show macOS notifications** on |
| Automation → iTerm2 | Jumping to the right iTerm tab, reading its folder |
| Screen Recording | Screenshots, and telling Cursor windows apart when several are open |
| Accessibility | Screen capture and desktop control (both off by default). Also used, when already allowed, to attach the frontmost app's text selection when you open chat |
| Microphone | Voice notes, spoken messages and meeting transcripts (each off by default) |
| Input Monitoring | Only when you choose Fn as the dictation shortcut. ironpet listens for Fn and never blocks it |
| Screen & System Audio Recording | The other party's audio in a meeting transcript (off by default) |

## Next steps

- [Using ironpet](/docs/using-ironpet/) lists the shortcuts and the main actions.
- [Agents](/docs/agents/) explains what Ghost shows while your agents work.
- [Chat](/docs/chat/) covers talking to an agent through Ghost.
- [Alerts](/docs/alerts/) sets up PR, CI and Sentry alerts.
- [Privacy](/docs/privacy/) explains what stays on your Mac.
