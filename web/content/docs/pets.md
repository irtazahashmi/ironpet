---
title: Pets
description: Rename your pet, switch to one of six bundled pets, or have your agent build a new one.
section: Features
order: 16
---

Ghost is the default, but you can rename it or pick another pet. Open **Settings → General → Pets**, click a pet and pick its image from the animated tiles.

## The six pets

| Pet | Look |
| --- | --- |
| `ghost` | White direwolf in a Night's Watch cloak (the default) |
| `mochi` | Mint wolf |
| `hamster` | Golden hamster with cheek pouches and buck teeth |
| `panda` | Panda with eye patches and black paws |
| `bunny` | Lilac bunny with long ears and a cotton tail |
| `cat` | Grey tabby with green eyes and a curly tail |

The pets are drawn in code, not from image files: the build generates each sprite sheet into the app, and every pet has the same animations. With Reduce Motion on, the tiles show one still frame.

Picking a pet also renames it, but only while the name is still a default one (a built-in pet's name or the previous pet's name). A name you typed stays. You can rename the pet in Settings, or with `pet.name` in [`config.json`](/docs/configuration/).

## Several pets

Each pet is an agent of its own. **Add pet** in Settings → General → Pets makes a new one, and clicking a pet opens its details: its name, its image, the harness it runs (Cursor, Claude Code, Codex and the others you have), the model (empty for the harness's default) and its own instructions.

Every pet that is on runs its own chat and stands on your screen, so Bunny can work in Claude Code while Ghost works in Cursor. Each one asks for approvals in its own bubble, and clicking a pet opens its chat. When two or more pets are on, the chat header has a switcher between them. Voice notes and spoken replies follow the pet you clicked last.

Turning a pet off stops its chat and hides it; its chats and automations stay, and come back when you turn it on again. Removing a pet keeps its chats and automations on disk but stops listing them. The first pet always stays.

## Your own pets

The gallery lists the six bundled pets, every valid PNG or WebP sprite sheet in `~/.ironpet/pets/`, and the current `pet.sprite` if it lives elsewhere. A sheet in `~/.ironpet/pets/` replaces the bundled pet of the same name, and files that are not valid sheets are skipped. New files appear within a couple of seconds while Settings is open.

**Add from file…** copies a sheet you choose into `~/.ironpet/pets/` and selects it.

Any sprite sheet in the Codex pet v2 layout works: 1536 px wide, 8 columns of 192×208 cells.

## Build a new pet

**Build a new pet** asks for a one-line description, then sends it to your current chat as, for example, `/ironpet-pets red fox with a scarf`. The chat's session and folder stay as they are.

The `ironpet-pets` skill ([`skills/ironpet-pets/SKILL.md`](https://github.com/irtazahashmi/ironpet/blob/main/skills/ironpet-pets/SKILL.md)) holds the atlas layout and the steps the agent follows: copy the generator (`make_pet.swift` in the app's Resources), add a theme, render, check, then move the sheet into `~/.ironpet/pets/`. When the agent writes the file, the new pet shows up in the gallery.

If no agent on your Mac has the skill, the click installs it first, the same way Settings → Skills does, and the skill then updates there like `ironpet-automations`. An agent session that was already running may need a restart to see a newly installed skill. If the agent is still running, or the chat has no folder yet, the request waits in the input box.

## Making a sheet by hand

From a clone of the repository, `tools/make_pet.swift` draws any of the bundled pets. Write the sheet into `~/.ironpet/pets/` and it joins the gallery:

```bash
swift tools/make_pet.swift cat ~/.ironpet/pets/cat.png
```

With `--single` it draws one idle pose at 5x, which `tools/make_icon.swift` turns into the app icon:

```bash
swift tools/make_pet.swift ghost --single build/pet.png && swift tools/make_icon.swift build/pet.png Resources/icon-1024.png
```

`pet.sprite` in `config.json` still takes a path to a sheet, and `~/.ironpet/pet/spritesheet.png` still overrides the default when `pet.sprite` is unset.
