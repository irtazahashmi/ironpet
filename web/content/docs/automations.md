---
title: Automations
description: Break reminders, scheduled jobs, watchers, the morning brief and background jobs, all as automations you or your agent can change.
section: Features
order: 11
---

Every reminder, watcher and scheduled job in ironpet is an automation. The easiest way to make one is to ask: ironpet window → Automations → **New automation…**, then describe what you want. Your agent creates it, runs it once and tells you what it made.

ironpet adds no automations on its own, so a fresh install has an empty list. The welcome window adds the break reminders and GitHub alerts only if you tick them.

## Break reminders

Three reminders are offered in the welcome window:

- **Drink water** every 45 minutes.
- **Stretch** every 60 minutes.
- **Rest your eyes** every 20 minutes.

They count only while you're at the keyboard, and stepping away for 5 minutes resets them. While an agent is working they can come a little early, so you take the break while you'd be waiting anyway. Ghost drinks or stretches along with you. His bubble has **Done** and **Snooze 10 min**.

They're ordinary automations, so an agent can add, change, pause and delete them. Toggle or pause them under right-click → Automations.

## Morning brief and recap

A digest is an automation you create with a `digest` action, `brief` or `recap`. Create one in ironpet window → Automations, or ask your agent, and pick the time there. ironpet builds a digest from data already on your Mac: no agent runs and no quota is spent.

- **The brief** lists Inbox items, open alerts (review requests and failing CI first), your unticked action items from recent meetings, and agents waiting for you.
- **The recap** lists agent turns that ended today with their summary line, alerts resolved today, today's meetings, and what is still open.

A bubble shows up to four lines and stays until the end of the day. **Open**, or the **Today** row in the sidebar, shows the full list. A scheduled brief with nothing in it stays quiet. A brief missed while the Mac slept still comes if you're back within three hours (two for the recap).

## What an automation is made of

Automations live in `~/.ironpet/automations.json`, which ironpet reloads within two seconds of an edit. An invalid edit leaves the last good list running and shows a bubble that names the problem. `automations.schema.json` next to it describes every field.

```json
{
  "automations": [
    { "id": "stretch", "name": "Stretch", "trigger": { "type": "interval", "minutes": 60, "clock": "active" },
      "action": { "type": "bubble", "title": "Stretch a bit", "body": "Stand up, roll your shoulders." },
      "presentation": { "mood": "stretching", "symbol": "figure.flexibility" } },
    { "id": "standup", "name": "Standup", "trigger": { "type": "daily", "times": ["09:55"], "weekdays": ["mon", "tue", "wed", "thu", "fri"] },
      "action": { "type": "bubble", "title": "Standup in 5" } }
  ]
}
```

### Triggers

- `interval`: every N minutes, on `active` keyboard time or the `wall` clock.
- `daily`: times of day, with optional weekdays.
- `once`: an exact date and time.
- `poll`: run a shell command or HTTP GET and fire once for each new item.
- `stream`: keep a command running (such as `fswatch` or `tail -f`) and fire for each line it prints.
- `script`: a small JavaScript function for watchers that compare with the last run.
- `inbox`: run once for each new Inbox item.

### Actions

- `bubble`: a speech bubble with a title, body, mood and **Done** and **Snooze** buttons.
- `prompt`: send a prompt to an agent, in the open chat or in a background session.
- `shell`: run a command and show its output.
- `digest`: the morning brief or the recap.

The full reference, including scripts, polls and streams, is in the [README](https://github.com/irtazahashmi/ironpet/blob/main/README.md#automations).

## Approval

A shell command, script or prompt that an agent created or changed waits for you to press **Approve** in a bubble before its first run, and asks again whenever its command, script or prompt changes. **Auto-approve automation changes** (`automations.autoApprove`, off by default) skips that bubble for agent-written changes on this Mac. It never covers a change made from a paired phone.

An agent that can write files on your Mac could also edit the approval records, so treat approval as a guard against mistakes, not against a hostile agent. Don't put secrets in `automations.json`; use `$ENV_VAR` references instead.

## When an automation fails

**Ask the pet to fix automations that fail** (`automations.autoFix`, on by default) sends a failing automation to the current chat in the background and asks your agent to find the cause and fix it. It asks once per failing stretch, at most every 6 hours per automation. A changed command still waits for your Approve.

## Logs and history

ironpet window → Automations has a **Show logs** button. It lists every run with its time, duration, outcome and output, and can filter by automation or show only problems. Logs are kept for 14 days by default (Keep logs for, or `automations.logRetentionDays`). The last 20 runs of each automation are also shown in its row.

## From the terminal

With the app running:

```bash
IronPet automations list
IronPet automations add --name "Check build" --command "make test" --every 30 --report chat --until success
IronPet automations pause <id>
IronPet automations run <id>
```

The terminal counts as an agent for approval.

## Background jobs

Ask Ghost to do something that takes a while ("fix the flaky login test in ironpet", "write up last week's PRs") and the chat agent can hand it to a background job instead of doing it in the chat. A job is its own agent session, with the chat's agent and model, in one folder. It shows in the Agents section as "Background job" with its last step, and Ghost tells you when it finishes or fails.

- **Which folder.** A job runs only in a folder ironpet knows: the front Cursor window, the chat's folder, folders open in Cursor, folders of watched agent sessions, or recent chat folders. Work that isn't about code runs in `~/.ironpet/scratch`.
- **Approvals.** A job runs in the agent's own mode. When the agent asks for permission, the job waits and ironpet raises an alert with the agent's own options as buttons. Nobody can approve one by voice or by asking the chat agent. After 10 minutes without an answer, the agent gets its reject option.
- **Talking to it.** Ask Ghost how it's going, or click the job's row to read its transcript in the chat. A message typed there goes to the job while it runs.
- **Limits.** At most 3 jobs run at once (`jobs.maxRunning`, 1 to 5); the rest wait in line. A turn that runs longer than an hour fails.

Ask "anything need me?" and Ghost gathers sessions that need you, jobs, Inbox items, open alerts and recent meetings in one answer.
