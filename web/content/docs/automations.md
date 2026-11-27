---
title: Automations
description: Break reminders, scheduled jobs, watchers, the morning brief and background jobs, all as automations you or your agent can change.
section: Features
order: 11
---

Every reminder, watcher and scheduled job in ironpet is an automation. The easiest way to make one is to ask: ironpet window → Automations → **New automation…** opens a box that asks what kind of automation you want. What you write goes to your agent in the current chat, which creates it with the automation tools, runs it once and tells you what it made.

ironpet adds no automations on its own, so a fresh install has an empty list. The welcome window adds the three break reminders and the GitHub alerts only if you tick them.

## Break reminders

Three reminders are offered in the welcome window:

- **Drink water** every 45 minutes.
- **Stretch** every 60 minutes.
- **Rest your eyes** every 20 minutes.

They count only while you're at the keyboard, and stepping away for 5 minutes resets them. While an agent is working they can come a little early, so you take the break while you'd be waiting anyway. Your pet drinks or stretches along with you. Its bubble has **Done** and **Snooze 10 min**.

The idle time and the snooze length stay in `config.json` as `reminders.idleResetMinutes` (5) and `reminders.snoozeMinutes` (10). See [Configuration](/docs/configuration/).

They're ordinary automations, so an agent can add, change, pause and delete them. Toggle or pause them under right-click → Automations.

## Morning brief and recap

A digest is an automation you create with a `digest` action: `"digest": "brief"` or `"digest": "recap"`. Create one in ironpet window → Automations, or ask your agent. ironpet builds a digest from data already on your Mac: no agent runs and no quota is spent.

- **The brief** lists Inbox items, open alerts (review requests and failing CI first; good news such as an approval is left out), your unticked action items from meetings since the last weekday, and agents waiting for you.
- **The recap** lists agent turns that ended today with their summary line, alerts resolved today, today's meetings, and what is still open.

A bubble shows up to four lines and stays until the end of the day. **Open**, or the **Today** row in the sidebar, shows the full list on the Today page. A scheduled brief with nothing in it stays quiet, and **Run now** shows "Nothing to report".

Both use `catchUpMinutes` (180 for the brief, 120 for the recap), so a slot missed while the Mac slept or ironpet was closed still comes when you're back within that time; older ones are skipped. Change the time and **Weekdays only** in the automation's row. A `digest` action can't be used with a `poll` trigger.

## The automations file

Automations live in `~/.ironpet/automations.json`. ironpet checks it and reloads it within two seconds of an edit. An invalid edit leaves the last good list running and shows a bubble that names the problem. `automations.schema.json` next to it describes every field.

```json
{
  "automations": [
    { "id": "stretch", "name": "Stretch", "trigger": { "type": "interval", "minutes": 60, "clock": "active" },
      "action": { "type": "bubble", "title": "Stretch a bit", "body": "Stand up, roll your shoulders." },
      "presentation": { "mood": "stretching", "symbol": "figure.flexibility" } },
    { "id": "standup", "name": "Standup", "trigger": { "type": "daily", "times": ["09:55"], "weekdays": ["mon", "tue", "wed", "thu", "fri"] },
      "action": { "type": "bubble", "title": "Standup in 5" } },
    { "id": "new-prs", "name": "New PRs", "trigger": { "type": "poll", "minutes": 5,
        "source": { "type": "shell", "command": "gh pr list --json number,title,url" }, "items": "[?!isDraft]", "id": "number" },
      "action": { "type": "bubble", "title": "New PR: {{item.title}}", "body": "{{item.url}}" } }
  ]
}
```

Secrets don't belong in `automations.json`. Use `$ENV_VAR` references instead.

## Triggers

- `interval`: every N minutes, on `active` keyboard time or the `wall` clock.
- `daily`: times of day, with optional weekdays and an optional `catchUpMinutes`. A slot missed while the Mac slept or ironpet wasn't running fires when you're back, if it's at most that many minutes late. `0` fires on time only.
- `once`: an exact date and time. It turns itself off afterwards.
- `poll`: run a shell command or HTTP GET and fire once for each new item. See [Polls](#polls).
- `stream`: keep a command running and fire for each line it prints. See [Streams](#streams).
- `script`: a small JavaScript function for watchers that compare with the last run. See [Scripts](#scripts).
- `inbox`: run once for each new Inbox item. See [Inbox](/docs/inbox/#automations-on-new-items).

### Polls

- **Source.** A shell command or an HTTP GET. HTTP header values must be `${ENV_VAR}` references.
- **Items.** A [JMESPath](https://jmespath.org) expression in `items` picks the items, with `id` and `version` expressions that run on one item. Instead of `items`, you can use `lines`, `text` or `exit_code` mode.
- **Filtering.** Filters do the filtering, for example `"items": "data.runs[?conclusion=='failure']"` or `[?contains(['open', 'new'], state)]`. JMESPath has no regular expressions. It runs inside ironpet, so nothing like `jq` has to be installed.
- **What fires.** The first run only records what exists. After that each new `id`, or a changed `version`, fires once.

### Streams

A `stream` trigger keeps a shell command running and fires the action for each line it prints, with no polling. Use it with `fswatch`, `log stream`, `tail -f`, `gh run watch` or any CLI with a watch mode.

- `mode` is `lines` (the default, with the line in `{{item.line}}`) or `json` (one JSON value per line, with `items`, `id` and `version` as in a poll).
- `when` is a JMESPath filter that must be truthy for the event to fire.
- `debounceSeconds` fires once after that long without a new event, with the latest event and `{{count}}`, the number of merged events.
- `throttleSeconds` allows one fire per that many seconds.
- While an action runs, only the newest waiting event is kept.

ironpet starts the command when the automation is on and approved. It stops the command and its children when you pause, delete or change the automation or quit, and restarts it when it exits, with a wait of 1 second, doubling up to 5 minutes. Lines over 64 KiB and more than 20 events a second are dropped and logged, and stderr goes to the log. A stream an agent writes or changes waits for **Approve** like a shell command.

```json
{ "id": "new-pdfs", "name": "New PDFs in Downloads",
  "trigger": { "type": "stream", "command": "fswatch --event Created ~/Downloads | grep --line-buffered '[.]pdf$'", "debounceSeconds": 2 },
  "action": { "type": "bubble", "title": "{{count}} new PDF(s)", "body": "{{item.line}}" } }
```

### Scripts

A `script` trigger is a small JavaScript function for watchers that need to compare with the last run. A script automation has no `action` field: the script returns its own actions.

```js
function poll(state) {            // state is what the last run returned, null the first time
  const prs = JSON.parse(sh("gh pr list --json number,title,url,statusCheckRollup").stdout);
  const now = Object.fromEntries(prs.map(p => [p.number, p.statusCheckRollup]));
  const actions = [];
  for (const p of prs) {
    if (now[p.number] === "FAILURE")
      actions.push({ type: "alert", id: String(p.number), severity: "bad", label: "CI failed", title: p.title, url: p.url });
    else if (state && state[p.number] === "FAILURE")
      actions.push({ type: "alert", id: String(p.number), resolved: true });
  }
  return { state: now, actions };   // state is kept for the next run
}
```

The return value is `{state, actions}`. `state` is any JSON, up to 256 KiB, and is passed to the next run. Return `done: true` to delete the automation, as with [`until`](#background-automations-with-until).

#### Script actions

`actions` run in order, up to 20 per run. Each has a `type`:

- **`bubble`** shows a short-lived popup: `title`, `body`, `severity` (`info`, `good`, `warn`, `bad`), `url` (adds an **Open** button), `symbol`, `expiresSeconds`, `notification`, `description` (the full text, markdown, up to 64 KiB, shown in [Notifications](/docs/notifications/)) and `links` (see [Links](/docs/notifications/#links)). A bubble with the same `id` replaces the old one.
- **`alert`** keeps an open item in the alerts list, which also drives your pet's mood and badge: `id`, `title`, `subtitle`, `label`, `severity`, `url`, `ask` (the prompt for **Ask**, the button with your pet's name), `version`, `description` and `links` (kept with the notification that announces it). A new or changed alert also gets a bubble, except on the first run, which is quiet. An alert listed again unchanged is left alone, even if you dismissed it. `{type: "alert", id, resolved: true}` removes it. See [Alerts](/docs/alerts/).
- **`prompt`** asks an agent in a background session and shows the answer: `prompt`, `title`, `agent`, `model`.
- **`chat`** posts a system notice to the main chat, the same notice as a `prompt` action with `report: "chat"`: `text` (up to 64 KiB) and `title`. It starts a turn, and a newer notice from the same automation replaces one the agent hasn't read yet.
- **`suggest_task`** adds an Inbox item from something a watcher found, such as an email, a Slack message or an issue: `id` (stable for that thing), `title`, `due` (`YYYY-MM-DD`), `notes`, `url`. The same `id` from the same automation is added once, even after you marked it done or removed it. Titles are cut at 200 characters and notes at 2000, control characters are removed, and at most 10 are taken per run. The first run adds them quietly; after that each run with something new shows one bubble. See [Inbox](/docs/inbox/#watchers).
- **`dashboard`** merges `data` into a dashboard's storage: `{type: "dashboard", id, data}`. See [Dashboards](/docs/dashboards/#feeding-a-dashboard-from-an-automation).

#### What a script can do

- `sh(command, {timeoutSeconds})` runs a command and returns `{code, stdout, stderr, timedOut}`. For the network, run `curl` through `sh`.
- `console.log` writes to the automation's [logs](#logs-and-history).
- Limits per run: at most 8 `sh` calls and 60 seconds in all, 32 MiB of memory and 256 KiB of state.
- It runs in QuickJS inside ironpet, with no `fetch`, files, modules or timers. `poll` must be a plain function, not `async`.
- A script an agent writes or changes waits for **Approve** like a shell command.
- Its state and the alerts it has shown are in `ironpet.db`.

## Actions

- **`bubble`**: a speech bubble with a title, body, mood, SF Symbol, **Done** and **Snooze** buttons, and an optional macOS notification.
- **`prompt`**: sends a prompt to an agent. By default it goes into the open chat. See [Prompt actions](#prompt-actions).
- **`shell`**: runs a command with a timeout and shows its output.
- **`digest`**: the [morning brief or the recap](#morning-brief-and-recap), built on the Mac with no agent. Not for `poll`.

Text may use `{{item.field}}` from polls, streams and the inbox trigger, plus `{{name}}` and `{{now}}`.

### Prompt actions

By default (`"session": "main"`; `"chat"` is the older name for it), a `prompt` action sends the prompt into the open chat under a header naming the automation, so the chat's agent runs it with its tools, memory and context. It queues behind a running turn, skips a tick while its previous run is still queued or running, and ignores `agent` and `model`.

A prompt that uses `{{item.field}}` runs in a read-only background session of its own instead, and shows the answer in a bubble.

#### Sessions

`session` decides where the prompt runs:

| `session` | Where it runs |
| --- | --- |
| `main` (default) | In the open chat. |
| `new` | A fresh agent session every run. |
| `own` | One thread per automation, resumed each run. |
| `fork` | A copy of the main chat's agent session, so the run knows the recent conversation. |

- **`own`.** When its agent session passes `chat.sessionRolloverMB`, the next run asks the old session for a summary and continues in a fresh agent session of the same thread, with the memory notes, the summary and the last messages, so it still knows what it reported. Agents other than Claude Code start a fresh thread after 50 runs instead.
- **`fork`.** It needs an agent that supports `session/fork` and a chat that uses the same agent. Otherwise it runs as `new` and the logs record a warning.
- **Tools.** `new`, `own` and `fork` runs have the agent's full tools minus `disallowedTools`. `allowedTools` lists tools that need no asking. A prompt that uses `{{item.*}}` stays read-only.
- **History.** Each run is saved as a thread marked as an automation run in Previous chats.

The prompt can be a slash skill, for example on an hourly interval:

```json
{ "type": "prompt", "prompt": "/am-check-emails 1", "session": "new", "quiet": "NOTHING_NEW" }
```

#### Reporting to the chat

`"report": "chat"` posts the answer of a `new`, `own` or `fork` run to the open chat as a system notice instead of a bubble. It's the default for `fork`, and without a `session` it runs as `new`.

- The chat shows one muted line, such as "Automation: Morning brief", that expands to the answer.
- The chat's agent gets the same text once, with its next turn, marked as data and not as instructions. A non-empty answer also starts a turn.
- An empty answer, `NOTHING`, `NOTHING_NEW` or the `quiet` reply posts nothing.
- A failed run posts a notice without starting a turn.

```json
{ "type": "prompt", "prompt": "/am-check-emails 1", "session": "new", "report": "chat", "quiet": "NOTHING" }
```

#### Quiet replies

`quiet` works on any `prompt` action. A run whose final reply is exactly that text is hidden. It can be a string or a list.

```json
{ "type": "prompt", "prompt": "...", "quiet": "ALL_CLEAR" }
```

### Shell actions that report to the chat

A `shell` action takes `"report": "chat"` to post its result to the main chat instead of a bubble: the command, the exit code and the last 4 KB of output, as a system notice the chat's agent reads. Exit code 0 starts a turn, a failure posts a notice without starting one, and `quiet` output posts nothing.

### Background automations with until

`until` on the automation deletes it once its job is done:

- `"until": "success"` deletes it after the first run whose action succeeded, such as a shell command that exits 0.
- `"until": "once"` deletes it after the first completed run.
- A script returns `done: true` for the same.

The history keeps a `deleted` line. Together with `report: "chat"`, this makes an automation a background job that survives restarts of ironpet and the chat, such as a PR merge watch:

```bash
IronPet automations add --name N --command CMD --every MIN --report chat --until success
```

## Approval

A `shell` action, a `shell` poll source, a `stream` command, a `script` trigger or a `prompt` action that an agent created or changed waits for you to press **Approve** in a bubble before its first run, and asks again whenever its command, script or prompt changes. Saved approvals live in `~/.ironpet/ironpet.db`.

Settings → Automations → **Auto-approve automation changes** (`automations.autoApprove`, off by default) skips that bubble for agent-written changes on this Mac. It never covers a change made from a paired phone.

An agent that can write files on your Mac can edit that database too, so treat approval as a guard against mistakes, not against a hostile agent.

## When an automation fails

Settings → Automations → **Ask the pet to fix automations that fail** (`automations.autoFix` in `config.json`, on by default). When a poll, script, shell command or prompt fails, ironpet sends it to the current chat in the background and asks your agent to find the cause and fix the automation with the automation tools.

- The error from the run goes in the message marked as data, not instructions.
- Your pet says when the agent needs you.
- It asks once per failing stretch, at most every 6 hours per automation, and not for paused automations or ones still waiting for approval.
- A changed command, script or prompt still waits for your **Approve**.
- If the chat is busy, a bubble offers to send it instead.

## Logs and history

ironpet window → Automations has a **Show logs** button. Each row's menu also has **Show logs…**, and so does right-click your pet → Automations. The logs window lists every poll and script run, quiet ones included, plus every reminder, shell command and prompt that ran: time, how long it took, the outcome and the output. That's the exit code, stdout and stderr of a poll, the `console.log` lines and actions of a script, or the error of a failed run. Filter by automation or show only problems.

- Logs are kept for 14 days by default. Set it under Settings → Automations → **Keep logs for**, or `automations.logRetentionDays` in `config.json` (1 to 365).
- At most 2000 lines are kept per automation.
- The last 20 runs of each automation (time, outcome, short output) are shown in its row and returned by `automations_history`.

## Automation tools for agents

Your pet's chat agents get these MCP tools: `automations_list`, `automations_get`, `automations_create`, `automations_update`, `automations_delete`, `automations_pause`, `automations_resume`, `automations_run_now` and `automations_history`.

They reach the app through `IronPet mcp`, a stdio MCP server that forwards to the running app. To add it to another agent, for example Claude Code:

```bash
claude mcp add ironpet -- /Applications/IronPet.app/Contents/MacOS/IronPet mcp
```

Other agents take the same command and argument in their MCP settings. ironpet doesn't edit their config files.

You can also post to `http://127.0.0.1:<port>/mcp`, with the port in `~/.ironpet/port` and the token in `~/.ironpet/token`, sent in the `x-ironpet-token` header.

## Skills

ironpet ships agent skills. The first one, `ironpet-automations`, shows an agent how to create automations: which trigger to pick, the script format, the safety rules and how to debug a run. When you ask your pet to check or watch something regularly, it uses this skill, and puts the prompt in a skill of its own when it needs one.

### Managing skills

Manage them in Settings → General → **Skills**: **Install**, **Update**, **Reinstall** and **Remove** for each skill, and a switch, **Install and update skills automatically**, on by default.

- **Where they go.** ironpet installs one real copy in `~/.agents/skills/<name>`, which Codex, Cline, Pi, Warp, Zed and other agents read directly, and a relative symlink from the skills folder of every other agent found on your Mac (`~/.claude/skills`, `~/.cursor/skills`, `~/.gemini/skills`, and so on). A folder with the same name that ironpet didn't write is left alone.
- **Automatic updates on.** Skills that are missing or out of date are installed or updated at launch for the agents found on your Mac, and your pet says so in one bubble.
- **Automatic updates off.** When an agent is installed and a skill is missing or old, your pet shows one bubble for all of them with an **Install** (or **Update**) button.
- **Not now.** A skill you decline with **Not now** stays out, and quiet, until its text changes.

From the terminal:

`IronPet skills install|status|update|remove|list|agents`. `install` can pick a skill, the agents and copy mode:

```bash
IronPet skills install ironpet-automations --agent claude-code --copy
```

### Adding a skill to ironpet

If you build ironpet from source, skills are folders `skills/<name>/SKILL.md` in the repo. To add one, make `skills/<name>/SKILL.md` with frontmatter that has `name` (the same as the folder) and `description`, then run `python3 scripts/gen_skills.py`. It compiles the skills into the app. A test fails if you forget.

## From the terminal

`IronPet` is the app's own executable, `/Applications/IronPet.app/Contents/MacOS/IronPet`. The app must be running.

```bash
IronPet automations list
IronPet automations get <id>
IronPet automations add --name "Stretch" --every 60
IronPet automations add --name "Check build" --command "make test" --every 30 --report chat --until success
IronPet automations add --json '{...}'
IronPet automations update <id> --json '{...}'
IronPet automations pause <id>
IronPet automations resume <id>
IronPet automations delete <id>
IronPet automations run <id>
IronPet automations history <id>
```

The terminal counts as an agent for approval.

## Where state lives

- **Definitions** stay in `~/.ironpet/automations.json`.
- **Everything else** (seen sets, run history, approvals, snoozes and the last slot each catch-up `daily` automation fired) lives in `~/.ironpet/ironpet.db`, ironpet's common SQLite database (WAL), in `automation_*` tables.
- Seen items older than 7 days and history older than 30 days are pruned.
- If the database can't be opened (for example because a newer ironpet build created it), ironpet leaves it untouched, shows an alert with the reason and the path, and runs in memory, so nothing written meanwhile is saved. For a file from a newer build, install that build again to get your data back.

## Background jobs

Ask your pet to do something that takes a while ("fix the flaky login test in ironpet", "write up last week's PRs") and the chat agent can hand it to a background job with `jobs_start` instead of doing it in the chat. A job is its own agent session, with the chat's agent and model, in one folder. It shows in the Agents section as "Background job" with its last step, and your pet tells you when it finishes or fails.

### Which folder

`projects_resolve` matches what you called the project to the folders ironpet knows: the front Cursor window, the chat's folder, folders open in Cursor, the folders of agent sessions ironpet watches (so a Claude Code in iTerm counts), and recent chat folders. With no name it uses the project you're in, and it asks when two match. Work that isn't about code runs in `~/.ironpet/scratch`. A job never runs in a folder outside that list.

### Approvals

A job runs in the agent's own mode. When the agent asks for permission, the job waits and ironpet raises an alert (in the alerts list, as a bubble and as a macOS notification) that names the job and the tool, with the agent's own options as buttons. The phone and Telegram show the same request with allow and deny. Nobody can approve one by voice or by asking the chat agent. A closed bubble comes back when you open the job.

After `jobs.permissionTimeoutMinutes` (10 by default) without an answer, the agent gets its reject option and the job's result notes `permission timed out`.

### Talking to a job

- Ask your pet how it's going (`jobs_list`, `jobs_get`), open its transcript in the chat (`jobs_open`), add to it (`jobs_followup`) or stop it (`jobs_stop`).
- Starting, adding to and stopping a job asks first when the chat's mode asks about tools.
- Click the job's row to read its transcript in the chat. A message typed there goes to the job while it runs.

### Limits

- At most `jobs.maxRunning` jobs run at once (3 by default, from 1 to 5); the rest wait in line.
- A turn that runs longer than an hour fails.
- A job that was running when ironpet quit shows as interrupted.

### What's going on

Ask "anything need me?" and your pet answers with `status_overview`, which gathers the agent sessions that need you or are running, jobs, Inbox items, open alerts and recent meetings in one call. `status_sessions`, `status_alerts`, `status_today` (the brief or the recap) and `status_meetings` (with your open action items) give the details. The status tools run without an approval card.

### Memory

A job starts with the same notes as a new chat and has the same [memory](/docs/memory/) tools. What it saves is marked as coming from the job and goes to its folder's project unless it names another. Its transcript is searchable with `memory_search`, but the learning pass doesn't read it, since its first message is the chat agent's instructions rather than yours.

### Where jobs are kept

Jobs are in `~/.ironpet/ironpet.db` (`jobs` table) for 30 days after they end, and each job's transcript is a thread in `~/.ironpet/threads`, like a chat.

## Upgrading from an earlier version

- **Heartbeat.** ironpet no longer has a heartbeat. At the first launch of this version it deletes the built-in `heartbeat` automation (id `heartbeat`, which sent `/heartbeat`) and the bundled `heartbeat` skill if you hadn't edited it. It never changes `~/.ironpet/HEARTBEAT.md`; delete that file yourself if you don't need it.
- **Task reviews.** Earlier versions added a `review-tasks` automation ("Review tasks", `/ironpet-tasks` every 10 minutes), and later `task-review` and `weekly-review`. ironpet no longer adds them. One you edited, or wrote yourself, stays but has no tasks to read; delete it in Settings or from `automations.json`.
- **Built-in automations.** Earlier versions added `morning-brief`, `day-recap`, `mail-calendar` and the GitHub and Sentry alerts, switched off. At launch ironpet removes a copy you never switched on or edited, and keeps one you turned on or changed as your own automation. A deleted one doesn't come back. The mail and calendar prompt is still editable in Settings → Prompts, and a `mail-calendar` automation you kept keeps using it.
- **Paused reminders.** An old `reminders.paused` value in `config.json` is ignored.
