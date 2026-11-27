---
title: Notifications
description: How Ghost's speech bubbles work, how to get macOS notifications too, and the welcome back summary.
section: Features
order: 12
---

Ghost speaks in bubbles beside him instead of macOS notifications. Every bubble is also stored in the Notifications section of the ironpet window, so you can read the full text later.

## Bubbles

- **Approvals** stay until you answer.
- **Reminders** stay for 3 minutes.
- **Everything else** fades after 15 to 45 seconds, but not while the pointer is over it.

## The Notifications section

Clicking a bubble opens the Notifications section on that entry. It sits next to Alerts and has an unread badge. There you read the full description and open its links. Opening an entry, or pressing **Done** on its bubble, marks it read; **Snooze** leaves it unread. Entries are listed newest first, with filters for type and source and a **Mark all as read** button.

Stored entries include reminders, digests, approval requests, alert announcements and the results of background prompts. Entries older than 90 days are deleted.

## macOS notifications

To get macOS notifications as well, turn on right-click Ghost → **Also show macOS notifications**. Then set ironpet's notification style to **Alerts** in System Settings → Notifications, so the Allow and Deny buttons stay on screen.

## Welcome back

When you come back after being away, Ghost sums up what happened in one bubble instead of the ones you missed: "demo-app is waiting for you", "CI failed: irtaza/ironpet #84", "2 agents finished". Each line opens what it names.

- **Away** means 5 minutes idle by default (the same idle time as the break reminders, `reminders.idleResetMinutes`), or after the Mac slept.
- A call (any app using the microphone) or a meeting recording doesn't count as away.
- The summary is built from what ironpet already recorded on your Mac. No agent runs and nothing is sent anywhere.

Turn it off in Settings → General (`welcomeBack.enabled`).
