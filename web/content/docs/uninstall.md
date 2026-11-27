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

The script:

- removes only ironpet's entries from the agents' configs, so your other hooks stay,
- deletes the two files ironpet owns, Copilot's `ironpet.json` and Pi's `ironpet.ts`,
- removes the login item, the app, its Keychain items (the Sentry token, the voice API key, the Telegram bot token and the voiceprint key, with the stored voiceprints) and the app's preferences.

The `*.ironpet-backup` files are kept, since they're your configs from before ironpet.

## With Homebrew

If you installed with Homebrew:

```bash
brew uninstall --cask ironpet
```

Add `--zap` to delete its preferences too.

## Removing your data by hand

All of ironpet's data is in `~/.ironpet`. Delete the folder to erase it. See [Your data](/docs/your-data/) for what's inside.

To stop watching agents without uninstalling, turn off **Track coding agents** in Settings → General. That removes ironpet's hooks from every agent.

Keychain items for a Telegram bot token or a voice API key can be removed in Settings → Integrations and Settings → Voice, or from the terminal:

```bash
security delete-generic-password -s ironpet.telegram
security delete-generic-password -s ironpet.voice
```
