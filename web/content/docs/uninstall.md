---
title: Uninstall
description: Remove ironpet, its agent hooks and, if you want, all of its data.
section: Reference
order: 19
---

How you remove ironpet depends on how you installed it. Each way removes only ironpet's own hook entries, so your other hooks stay.

## Installed from the DMG

1. Quit ironpet (right-click Ghost → Quit ironpet).
2. Remove its hooks and login item:

   ```bash
   /Applications/IronPet.app/Contents/MacOS/IronPet --uninstall
   ```

3. Drag IronPet from Applications to the Trash.
4. Delete the Keychain items ironpet saved, if any, and the stored voiceprints:

   ```bash
   for name in ironpet.sentry ironpet.voice ironpet.voiceprints ironpet.telegram; do
     security delete-generic-password -s "$name" 2>/dev/null
   done
   rm -rf ~/Library/Application\ Support/IronPet
   ```

5. Delete the preferences with `defaults delete dev.ironpet.app`, and delete `~/.ironpet` if you don't want to keep your settings, chats and notes.

## Built from source

```bash
./scripts/uninstall.sh            # asks before deleting ~/.ironpet and the signing identity
./scripts/uninstall.sh --purge    # deletes everything without asking
```

`--yes` does the same as `--purge`. The script:

- quits ironpet,
- removes only ironpet's entries from the agents' configs (such as `~/.cursor/hooks.json`, `~/.claude/settings.json`, `~/.codex/hooks.json` and `~/.gemini/settings.json`), so your other hooks stay,
- deletes the two files ironpet owns, Copilot's `ironpet.json` and Pi's `ironpet.ts`,
- removes the login item and the app,
- deletes the Sentry token, the voice API key and the voiceprint key from the Keychain, with the stored voiceprints,
- deletes the app's preferences and the hook bridge in `~/.ironpet` (`bin/` and `port`),
- asks before deleting the rest of `~/.ironpet` (settings, saved chats, memory, screenshots) and the local `ironpet-dev` code signing identity.

It keeps:

- the `*.ironpet-backup` files, since they're your configs from before ironpet,
- the Telegram bot token in the Keychain; remove it in Settings → Integrations before you uninstall, or [from the terminal](#removing-your-data-by-hand),
- MCP sign-ins copied by **Share MCP sign-ins across folders**, which stay in `~/.cursor/projects/*/mcp-auth.json` until you sign out of those servers.

## With Homebrew

If you installed the notarized release with Homebrew (`brew install --cask irtazahashmi/ironpet/ironpet`, Apple Silicon only):

```bash
brew uninstall --cask ironpet
```

Add `--zap` to delete its preferences too. See the [tap](https://github.com/irtazahashmi/homebrew-ironpet) for details.

## Removing your data by hand

All of ironpet's data is in `~/.ironpet`. Delete the folder to erase it. See [Your data](/docs/your-data/) for what's inside.

To stop watching agents without uninstalling, turn off **Track coding agents** in Settings → General. That removes ironpet's hooks from every agent.

Keychain items for a Telegram bot token or a voice API key can be removed in Settings → Integrations and Settings → Voice, or from the terminal:

```bash
security delete-generic-password -s ironpet.telegram
security delete-generic-password -s ironpet.voice
```
