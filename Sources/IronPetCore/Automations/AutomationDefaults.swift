import Foundation

/// The GitHub and Sentry alerts that ironpet starts with. They are ordinary script automations, written by the user's
/// own account (`createdBy: user`), so they run without approval and anyone can read and change them in `automations.json`.
package enum AutomationDefaults {
    package static let githubID = "github-alerts"
    package static let sentryID = "sentry-alerts"

    package static let morningBriefID = "morning-brief"
    package static let dayRecapID = "day-recap"
    /// The automations that belong to this install, not to an agent: they are listed for every agent and run as they always have.
    /// The memory pass is not an automation, so it needs no entry.
    package static let nodeLevelIDs: Set<String> = [morningBriefID, dayRecapID, taskReviewID, taskScanID, mailCalendarID]
    package static let weekdays = ["mon", "tue", "wed", "thu", "fri"]

    /// The built-in morning brief: what needs the user today, at 09:00 on weekdays. Off until the user turns it on. A brief
    /// missed while the Mac slept or was off still comes until noon.
    package static func morningBrief(enabled: Bool = false) -> Automation {
        Automation(id: morningBriefID, name: "Morning brief", enabled: enabled,
                   trigger: .init(type: "daily", times: ["09:00"], weekdays: weekdays, catchUpMinutes: 180),
                   action: .init(type: "digest", digest: "brief"), presentation: .init(symbol: "sun.max.fill"), createdBy: "user",
                   note: "Tasks due, tasks that need you, open alerts, meeting action items and waiting agents. Built from data on this Mac; no agent runs.")
    }

    /// The built-in end-of-day recap: what happened today, at 18:00 on weekdays. Off until the user turns it on.
    package static func dayRecap(enabled: Bool = false) -> Automation {
        Automation(id: dayRecapID, name: "End-of-day recap", enabled: enabled,
                   trigger: .init(type: "daily", times: ["18:00"], weekdays: weekdays, catchUpMinutes: 120),
                   action: .init(type: "digest", digest: "recap"), presentation: .init(symbol: "moon.stars.fill"), createdBy: "user",
                   note: "What agents finished, tasks closed, alerts resolved, meetings held and what is still open. Built from data on this Mac; no agent runs.")
    }

    package static let weeklyReviewID = "weekly-review"

    /// The built-in weekly review: GTD's review prepared from data on this Mac, Fridays at 15:00. Off until the user turns it on.
    package static func weeklyReview(enabled: Bool = false) -> Automation {
        Automation(id: weeklyReviewID, name: "Weekly review", enabled: enabled,
                   trigger: .init(type: "daily", times: ["15:00"], weekdays: ["fri"], catchUpMinutes: 240),
                   action: .init(type: "digest", digest: "review"), presentation: .init(symbol: "checklist"), createdBy: "user",
                   note: "The inbox to clarify, projects without a next action, follow-ups, what comes back next week, someday ideas, goals and how much of the week served them. Built from data on this Mac; no agent runs.")
    }

    package static let taskReviewID = "task-review"

    /// The built-in task review: every 20 minutes of clock time, in its own agent session that reports to the chat. Its prompt is
    /// `prompts/task-review.md`, read on each run. A reply of NOTHING posts nothing. On by default, as the issue asks.
    package static func taskReview(enabled: Bool = true) -> Automation {
        Automation(id: taskReviewID, name: "Task review", enabled: enabled,
                   trigger: .init(type: "interval", minutes: 20, clock: "wall"),
                   action: .init(type: "prompt", prompt: "{{prompt.\(taskReviewID)}}", session: "own", report: "chat"),
                   presentation: .init(symbol: "checklist"), createdBy: "user",
                   note: "Looks at open tasks and suggestions every 20 minutes and posts only what changed. Its prompt is in Settings → Prompts.")
    }

    package static let taskScanID = "task-scan"

    /// The task scan: a system automation that reads what is new in chats, meetings and the screen and files task suggestions. App
    /// code defines it on every launch, so a new version can change it. It is never written to `automations.json`, and the Automations
    /// list and the automation tools do not show it. Settings → Tasks turns it off and sets the interval.
    package static func taskScan(minutes: Int) -> Automation {
        Automation(id: taskScanID, name: "Task scan", enabled: true,
                   trigger: .init(type: "interval", minutes: Double(max(1, minutes)), clock: "wall"),
                   action: .init(type: taskScanAction), presentation: .init(symbol: "text.magnifyingglass"), createdBy: "user",
                   note: "Reads new chats, meeting summaries and screen captures and suggests tasks. Its prompt is in Settings → Prompts.")
    }

    /// The `action.type` of the task scan. It is not one of `AutomationValidator.actionTypes`, so a file cannot ask for it.
    package static let taskScanAction = "task-scan"

    /// The system automations that run for these settings. None when the task scan is switched off.
    package static func system(for tasks: Config.Tasks) -> [Automation] {
        tasks.scan ? [taskScan(minutes: tasks.scanMinutes)] : []
    }

    package static let mailCalendarID = "mail-calendar"

    /// The built-in mail and calendar checks: every hour, in its own agent session that reports to the chat. It proposes tasks
    /// from new mail and upcoming events, using whatever mail and calendar tools the agent has. Its prompt is
    /// `prompts/mail-calendar.md`. Off until the user turns it on.
    package static func mailCalendar(enabled: Bool = false) -> Automation {
        Automation(id: mailCalendarID, name: "Mail and calendar checks", enabled: enabled,
                   trigger: .init(type: "interval", minutes: 60, clock: "wall"),
                   action: .init(type: "prompt", prompt: "{{prompt.\(mailCalendarID)}}", session: "own", report: "chat"),
                   presentation: .init(symbol: "envelope.badge"), createdBy: "user",
                   note: "Checks new mail and the next 48 hours of events each hour and suggests tasks. Needs a mail or calendar tool the agent can use. Its prompt is in Settings → Prompts.")
    }

    /// Every built-in, added to the file when its id is missing.
    package static var builtIns: [Automation] { [morningBrief(), dayRecap(), weeklyReview(), taskReview(), mailCalendar()] }

    /// The `gh` binary, which the GitHub script runs.
    package static var ghExecutable: URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `~/.ironpet/sentry.json`, written by `scripts/configure_sentry.sh`.
    package static var sentryConfig: URL { Paths.root.appendingPathComponent("sentry.json") }
    package static var sentryConfigured: Bool { FileManager.default.fileExists(atPath: sentryConfig.path) }

    package static func github(enabled: Bool) -> Automation {
        Automation(id: githubID, name: "GitHub PR and CI alerts", enabled: enabled,
                   trigger: .init(type: "script", minutes: 2, script: githubScript), action: .init(type: "none"), createdBy: "user",
                   note: "Polls every host gh is signed in to: CI on your PRs, approvals, changes requested, review requests.")
    }

    package static func sentry(enabled: Bool) -> Automation {
        Automation(id: sentryID, name: "Sentry alerts", enabled: enabled,
                   trigger: .init(type: "script", minutes: 2, script: sentryScript), action: .init(type: "none"), createdBy: "user",
                   note: "Needs ~/.ironpet/sentry.json and a Keychain token from scripts/configure_sentry.sh.")
    }

    /// Replaces the `builtin` GitHub and Sentry sources of an earlier build with these scripts, keeping `enabled`.
    /// Returns nil when there is nothing to replace.
    package static func replacingBuiltins(in data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], var list = root["automations"] as? [[String: Any]] else { return nil }
        var changed = false
        for (index, entry) in list.enumerated() {
            guard let source = (entry["trigger"] as? [String: Any])?["source"] as? [String: Any], source["type"] as? String == "builtin" else { continue }
            let enabled = entry["enabled"] as? Bool ?? true
            let replacement = source["name"] as? String == "sentry" ? sentry(enabled: enabled) : github(enabled: enabled)
            guard let encoded = try? JSONEncoder().encode(replacement), let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { continue }
            list[index] = object
            changed = true
        }
        guard changed else { return nil }
        root["automations"] = list
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    package static let githubScript = #"""
        // Alerts for your open PRs and review requests, from `gh api graphql` on every host gh is signed in to.
        const QUERY = 'query { viewer { pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title url repository { nameWithOwner } reviewDecision commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 50) { nodes { ... on PullRequest { number title url repository { nameWithOwner } author { login } } } } }';

        function hosts() {
          const text = sh('cat "$HOME/.config/gh/hosts.yml" 2>/dev/null').stdout;
          const found = text.split("\n").filter(l => /^[A-Za-z0-9][^\s:#]*:\s*$/.test(l)).map(l => l.replace(/:\s*$/, ""));
          return found.length ? found : ["github.com"];
        }

        function poll(state) {
          const before = state || { prs: {}, ids: [] };
          const prs = {}, open = [], actions = [];
          let answered = 0, failed = 0;
          for (const host of hosts()) {
            const r = sh("gh api --hostname " + host + " graphql -f query='" + QUERY + "'", { timeoutSeconds: 30 });
            let data = null;
            if (r.code === 0) { try { data = JSON.parse(r.stdout).data; } catch (e) {} }
            if (!data) { failed++; console.log(host + ": gh did not answer. " + (r.stderr || "").slice(0, 200)); continue; }
            answered++;
            for (const pr of data.viewer.pullRequests.nodes) {
              const key = host + "|" + pr.repository.nameWithOwner + "#" + pr.number;
              const commit = (pr.commits.nodes[0] || {}).commit || {};
              const ci = (commit.statusCheckRollup || {}).state || null;
              const review = pr.reviewDecision || null;
              const was = before.prs[key];
              const sub = pr.repository.nameWithOwner + " #" + pr.number;
              prs[key] = { ci, review };
              if (ci === "FAILURE" || ci === "ERROR") {
                open.push(key + ":ci");
                actions.push({ type: "alert", id: key + ":ci", severity: "bad", label: "CI failed", symbol: "xmark.octagon.fill", title: pr.title, subtitle: sub, url: pr.url,
                  ask: "CI is failing on " + pr.url + ". Use `gh pr checks` and the failing job's logs to find out why, and propose a fix." });
              } else if (was && ci === "SUCCESS" && ["PENDING", "EXPECTED", "FAILURE", "ERROR"].includes(was.ci)) {
                actions.push({ type: "bubble", id: key + ":ci-passed", severity: "good", symbol: "checkmark.seal.fill", title: "CI passed", body: pr.title + "\n" + sub, url: pr.url, expiresSeconds: 15 });
              }
              if (review === "CHANGES_REQUESTED") {
                open.push(key + ":changes");
                actions.push({ type: "alert", id: key + ":changes", severity: "warn", label: "Changes requested", symbol: "exclamationmark.bubble.fill", title: pr.title, subtitle: sub, url: pr.url,
                  ask: "Changes were requested on " + pr.url + ". Read the review comments with `gh pr view --comments` and summarize what I need to change." });
              } else if (was && review === "APPROVED" && was.review !== "APPROVED") {
                actions.push({ type: "bubble", id: key + ":approved", severity: "good", symbol: "hand.thumbsup.fill", title: "Approved", body: pr.title + "\n" + sub, url: pr.url, expiresSeconds: 15 });
              }
            }
            for (const pr of data.search.nodes) {
              if (!pr || !pr.number) continue;
              const key = host + "|" + pr.repository.nameWithOwner + "#" + pr.number;
              open.push(key + ":review");
              actions.push({ type: "alert", id: key + ":review", severity: "warn", label: "Review requested", symbol: "eye.fill", title: pr.title,
                subtitle: pr.repository.nameWithOwner + " #" + pr.number + (pr.author ? " by " + pr.author.login : ""), url: pr.url,
                ask: "I was asked to review " + pr.url + ". Summarize what the PR changes and anything risky I should look at." });
            }
          }
          if (answered === 0) return;                    // nothing answered: keep the old state and try again next time
          if (failed === 0) {                            // only drop alerts when every host answered
            for (const id of before.ids) if (!open.includes(id)) actions.push({ type: "alert", id, resolved: true });
          }
          return { state: failed === 0 ? { prs, ids: open } : before, actions };
        }
        """#

    package static let sentryScript = #"""
        // Alerts for new and escalating Sentry issues. Reads ~/.ironpet/sentry.json and the token in the Keychain.
        function fetchIssues(cfg, search) {
          const host = (cfg.host || "https://sentry.io").replace(/\/+$/, "");
          if (!/^https?:\/\/[A-Za-z0-9.:\-]+$/.test(host) || !/^[A-Za-z0-9_\-]+$/.test(cfg.org || "")) { console.log("sentry.json has a bad host or org"); return null; }
          let query = search;
          if (cfg.projects && cfg.projects.length) query += " project:[" + cfg.projects.join(",") + "]";
          const url = host + "/api/0/organizations/" + cfg.org + "/issues/?statsPeriod=24h&sort=date&limit=25&query=" + encodeURIComponent(query);
          // The token goes to curl through a pipe, so it never appears in the process list.
          const r = sh("printf 'Authorization: Bearer %s' \"$(security find-generic-password -s ironpet.sentry -a '" + cfg.org + "' -w)\" | curl -sS --max-time 20 --fail-with-body -H @- '" + url + "'", { timeoutSeconds: 30 });
          if (r.code !== 0) { console.log("sentry: " + (r.stderr || r.stdout).slice(0, 200)); return null; }
          try { return JSON.parse(r.stdout); } catch (e) { return null; }
        }

        function poll(state) {
          const before = state || { esc: [] };
          const read = sh('cat "${IRONPET_ROOT:-$HOME/.ironpet}/sentry.json" 2>/dev/null');
          if (read.code !== 0) { console.log("no sentry.json: run scripts/configure_sentry.sh"); return; }
          let cfg; try { cfg = JSON.parse(read.stdout); } catch (e) { console.log("sentry.json is not valid JSON"); return; }
          const fresh = fetchIssues(cfg, "is:unresolved firstSeen:-1h");
          const escalating = fetchIssues(cfg, "is:unresolved is:escalating");
          if (!fresh || !escalating) return;
          const actions = [], esc = [];
          const describe = (i) => (i.project ? i.project.slug : "sentry") + " · " + (i.count || "?") + " events" + (i.culprit ? " · " + i.culprit : "");
          const ask = (i) => "Investigate this Sentry issue: " + i.title + " (" + i.permalink + "). Use the Sentry MCP tools to read the issue details, stack trace and recent events, then find the likely cause in this codebase and propose a fix.";
          for (const i of fresh) actions.push({ type: "alert", id: "new:" + i.id, severity: "bad", label: "New error", symbol: "ant.fill", title: i.title, subtitle: describe(i), url: i.permalink, ask: ask(i) });
          for (const i of escalating) {
            esc.push("esc:" + i.id);
            actions.push({ type: "alert", id: "esc:" + i.id, severity: "bad", label: "Error spiking", symbol: "ant.fill", title: i.title, subtitle: describe(i), url: i.permalink, ask: ask(i) });
          }
          for (const id of before.esc) if (!esc.includes(id)) actions.push({ type: "alert", id, resolved: true });
          return { state: { esc }, actions };
        }
        """#
}
