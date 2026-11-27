---
title: Dashboards
description: Ask your pet for a small app of your own and it appears in the sidebar, with its own data and buttons that act.
section: Features
order: 10.5
---

A dashboard is a small app inside ironpet. Ask your pet for one in the chat, such as "a board of my agents grouped by state" or "my inbox count", and your pet writes it, plus the automation that feeds it when it needs fresh data. It appears as a row in the sidebar of the ironpet window. ironpet ships no example dashboards.

## What a dashboard can show

Dashboards are drawn with native components, not web pages: columns and rows, cards, text, stats, lists, tables, charts and buttons. A button can open a link, a file or the chat, change the dashboard's data, run what the dashboard is allowed to run, or send your pet a message.

- A message shows in the chat as sent by the dashboard, and your pet answers.
- A file opens in its app, except applications and scripts, which only show in Finder.

### The sidebar row

Each dashboard has a row in the sidebar, and an icon in the collapsed rail after the built-in ones, in the icon and colour you picked. The row shows a number when the manifest sets `count`: what the script's `count` function returns, or else the `count` key in its data.

## What a dashboard is made of

A dashboard is code, in the shape of a Herdr mod. It lives in `~/.ironpet/dashboards/<id>/`:

- **`manifest.json`** has the title, an SF Symbol `icon`, a `color`, `count` (whether the sidebar icon shows a number) and the `capabilities` the dashboard asks for.
- **`main.js`** default-exports a view built from native components (`Column`, `Row`, `Card`, `Text`, `Stat`, `List`, `Table`, `Chart`, `Button`) with click handlers. There are no web views and no HTML. It runs in the same QuickJS engine as [script automations](/docs/automations/#scripts).
- **`storage.json`** is the dashboard's own saved data, a JSON object up to 256 KiB. It's separate from `ironpet.db`.

A small `main.js`:

```js
export default {
  view(ctx) {
    return Column([
      Stat({ label: "Open PRs", value: String(ctx.data.open ?? 0), tone: "warn" }),
      Button({ label: "Ask the pet", onClick: () => ironpet.prompt("Which PR needs me first?") }),
    ]);
  },
  count(ctx) { return ctx.data.open ?? 0; },
};
```

`ctx.data` is the dashboard's saved data, and `count` feeds the number on the sidebar row.

## What a dashboard can reach

A script can reach nothing outside its sandbox except through `ironpet.*`, and each call needs a capability that the manifest declares and you approved:

| Capability | What it allows |
| --- | --- |
| `run` | Command-line prefixes, such as `gh pr list`, that run as you without a shell |
| `network` | The hosts it may contact |
| `read` | `inbox`, `alerts` and `agents` |
| `write` | `inbox`: marking an item done or removing it |
| `prompt` | A button that sends your pet a message |

- When a dashboard is added, ironpet asks you to approve what it declares.
- When an edit adds a capability, ironpet asks again and marks the new ones. **Deny** keeps what you approved before.
- Until you approve, the call throws and the dashboard shows the error instead of the data.

## Feeding a dashboard from an automation

A script automation can return a `dashboard` action to merge `data` into a dashboard's storage:

```js
{ type: "dashboard", id: "work", data: { open: 3 } }
```

The open dashboard updates without reopening. Posting to a dashboard that was deleted fails, and the automation's log says so. See [Script actions](/docs/automations/#script-actions).

## Dashboard tools for your pet

The chat agent has these MCP tools:

- `dashboards_list`, `dashboards_get`, `dashboards_create`, `dashboards_update` and `dashboards_delete`.
- `dashboards_data`: every dashboard's saved data, for answering questions about it.
- `dashboards_post`: merges data into a dashboard's saved data, and the open dashboard updates.

Dashboard data is data, never instructions.

## Changing and deleting

Each dashboard's header menu has **Change icon**, **Edit code**, **Capabilities** and **Delete**. You can also ask your pet to change it.

Edit `main.js` or `manifest.json` in any editor and the dashboard reloads within two seconds. Deleting a dashboard removes its folder, its icon and its approvals.

## On the iPhone

The phone's More tab lists your dashboards at the top with the same icons, colours and counts, and draws the same view. The Mac runs the script, so a dashboard shows only while the Mac is reachable. The phone can change the icon and read the capabilities; approving them is done on the Mac. See [iPhone](/docs/iphone/).
