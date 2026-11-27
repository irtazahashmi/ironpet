---
title: Alerts
description: Opt-in alerts for your pull requests, CI runs and Sentry issues, with a button to ask your pet about each one.
section: Features
order: 6
---

Alerts tell you when your PRs, CI runs or Sentry issues change. They're off by default. Once set up, open alerts show in the Alerts section of the ironpet window and drive your pet's mood and badge.

Each alert has two buttons: **Open** goes to the PR, run or issue, and **Ask** (with your pet's name) starts a chat to investigate it.

## GitHub alerts

GitHub alerts need the `gh` CLI, signed in. Turn them on in one of two ways:

- Tick GitHub alerts in the welcome window on first launch.
- Ask your agent for them: ironpet window → Automations → **New automation…**

A GitHub alert can poll every host `gh` is logged in to for:

- your PRs' CI failing or passing,
- approvals,
- changes requested,
- new review requests.

## Sentry alerts

Run the setup script from the repository:

```bash
./scripts/configure_sentry.sh
```

It asks for your Sentry host, org, projects and an auth token with the `event:read` and `project:read` scopes. It checks the token, stores it in the Keychain, and saves the rest in `~/.ironpet/sentry.json`.

A Sentry alert watches new and escalating issues, using the host and org from `~/.ironpet/sentry.json` and the token in the Keychain. Alerts poll Sentry's REST API, which is cheap and exact. **Ask** on an alert then investigates through the Sentry MCP.

## Alerts are automations

PR, CI and Sentry alerts are ordinary script automations. You can read and change them in `~/.ironpet/automations.json`, pause them, or ask your pet to adjust them. See [Automations](/docs/automations/).
