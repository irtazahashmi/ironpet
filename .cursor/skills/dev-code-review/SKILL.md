---
name: dev-code-review
description: >-
  ironpet code review workflow (macOS desktop pet: Swift AppKit + SwiftUI app,
  agent hooks, ACP chat, bundled Node adapters, install and e2e scripts).
  Classifies the diff by surface, opens the matching surface file (app.md,
  tooling.md), runs that surface's gates, checks safety, privacy defaults,
  config, docs and ownership, and emits one fixed review summary. Use
  PROACTIVELY when reviewing a diff, PR, or branch in this repo.
metadata:
  category: code-review
---

# ironpet code review

You are the code reviewer for ironpet. Gate merges on correctness, safety, privacy, maintainability and clear ownership. One review covers the whole diff, whatever surfaces it touches, and ends with the one summary block below.

ironpet is a macOS 14+ app built with SwiftPM (`Package.swift`: one executable target `IronPet`, one XCTest target). It runs with the user's permissions, edits other tools' config files (agent hooks), starts coding agents that can change files and run commands (ACP over stdio), listens on a local HTTP port, and can record audio. That is why safety comes first (`CONTRIBUTING.md` › Guidelines).

The design and the reasons behind it are in `SPEC.md`. Everything the app reads and writes is in `SECURITY.md`. Features and every `config.json` key are in `README.md`. These override generic skill defaults.

## Use this skill when

- Reviewing a diff, PR, or branch in this repo.
- Verifying "ready to merge" claims before approval.
- Auditing safety, privacy, ownership, or naming decisions in a change.

## Do not use this skill when

- The task is unrelated to reviewing code (feature planning, general Q&A).
- Another skill is a better fit and no review gate is needed.

## Establish the review scope

Before reviewing or running checks, state exactly what is being reviewed:

- **Pull request / branch**: compare the branch with the merge-base of its target branch and include committed changes.
- **Uncommitted work**: inspect `git status --short`, the unstaged diff, the staged diff, and every untracked file.
- **User-provided diff**: review only that diff and identify any surrounding contracts read for context.

List the changed files. Never silently omit untracked files or substitute a different baseline.

## Route the diff to surface files

Classify every changed path, then open the surface file for each surface touched, in this folder. Read the whole file; do not review a surface from memory.

| Changed paths | Surface | Open |
|---|---|---|
| `Sources/IronPet/**`, `Tests/IronPetTests/**`, `Package.swift` | App | [app.md](app.md) |
| `sidecar/**`, `scripts/**`, `tools/**`, `Resources/**`, `.github/**` | Tooling | [tooling.md](tooling.md) |
| `README.md`, `SPEC.md`, `SECURITY.md`, `CONTRIBUTING.md`, `docs/**` only | Docs | The [Docs](#checks-on-every-review) check below |
| Anything else (`.cursor/`, `.agents/`, `.gitignore`, `LICENSE`) | Repo | Structure and secrets checks below |

A change to the hook script (`Hooks/HookScript.swift`), `HookInstaller`, `ApprovalRules`, `EventServer`, `TestControl` or `scripts/install.sh` / `uninstall.sh` crosses both surfaces: review it under both files.

## Ground rules

Reviews are source-read-only by default. `swift build`, `swift test` and `scripts/bundle.sh` only write ignored artifacts (`.build/`, `build/`, `sidecar/node_modules`, `sidecar/out`). Do not edit tracked files, commit, or push unless the user explicitly asks for fixes.

These touch the user's real machine, so never run them during a review without asking first:

- `./scripts/install.sh` (replaces `/Applications/IronPet.app`, restarts it, may create a signing identity and ask for the login password).
- `./scripts/uninstall.sh` (removes hooks, the login item, Keychain items and maybe `~/.ironpet`).
- `python3 scripts/e2e.py` (relaunches the installed app in `--test-mode`, runs real agent turns on the user's quota, edits and restores `config.json` and hook files, and takes over the keyboard for `setup` and `settings`).
- `./scripts/configure_sentry.sh`, or anything that writes to `~/.cursor`, `~/.claude`, `~/.codex`, `~/.gemini`, `~/.copilot`, `~/.pi` or the Keychain.

When fixes are authorized, rerun the affected gates and record the before/after result.

One reviewer, one summary, one final status. Run every applicable gate, or state what was not run and why. Do not mark a review as approved if any applicable gate failed and was not fixed. If a gate failed and was fixed in-session, note the delta (for example `✅ 42 passed (was 2 failed before fix)`).

## Checks on every review

These apply whatever surfaces were touched.

1. **Safety**
   - Hooks only report status. The hook script keeps its short `curl` timeouts, always exits 0, and skips runs with `IRONPET_ACP_RUN` set. A hook that can block, slow down or fail an agent is **Critical**.
   - `ApprovalRules` decides what ironpet answers without a card. Allowing a new kind of tool call without a card, weakening the destructive pattern, or letting Auto mode skip a destructive command is **Critical** unless the PR says why and adds tests in `ApprovalRulesTests`.
   - The local server binds to `127.0.0.1` only and every request carries the token from `~/.ironpet/token` (mode `0600`). `/test/*` endpoints exist only in `--test-mode`. Breaking any of these is **Critical**.
   - Nothing outside `~/.ironpet` changes until the user presses **Start** in the welcome window or turns the feature on in Settings. Each file ironpet edits outside `~/.ironpet` is backed up once to `*.ironpet-backup`, and uninstall removes only ironpet's entries. A violation is **Critical**.
   - Changes to hooks, approvals, Auto mode, or anything that writes outside `~/.ironpet` without tests and a matching `SECURITY.md` update are **High** (`CONTRIBUTING.md`).

2. **Privacy and defaults**
   - New integrations that touch the network, credentials, the microphone or the screen are **off by default** (`Config` default `false`), and permissions are requested when the user first uses the feature, never at launch. A violation is **High**.
   - A new network destination, upload, or download is listed in `SECURITY.md`. A missing entry is **High**.
   - Downloads are pinned and checksum-verified, as the Bun download and the mermaid bundle are. An unverified download that is executed or bundled is **Critical**.

3. **Secrets and config**
   - Tokens and API keys live in the Keychain (`ironpet.voice`, `ironpet.sentry`), never in `config.json`, `threads/`, logs, UserDefaults or a committed file. A leak is **Critical**.
   - Nothing private is committed: tokens, chat transcripts, meeting audio, `~/.ironpet` content, signing identities.
   - A new setting goes in `Config` (`Support/Config.swift`) with a safe default and clamping, with a Settings control if most people would change it, and documented in the README's Configuration section. A setting read from somewhere else is **High**; an undocumented key is **Medium**.

4. **Structure and naming**
   - Files sit in the folder that owns their area (see the layout table in `app.md`). No parallel trees, no second copy of a helper that already exists.
   - UpperCamelCase Swift types and files named after their main type. No generic filenames (`Helpers.swift`, `Utils.swift`, `Misc.swift`) for domain logic.
   - No new SwiftPM target, package dependency, or npm dependency outside `sidecar/` without prior discussion (`CONTRIBUTING.md`). An undiscussed dependency is **High**.
   - A mismatch is at least **Medium**. The fix names the expected location and a safe rename or move.

5. **Docs**
   - Map the diff to the page that owns it: `README.md` for features, config keys, permissions and shortcuts; `SPEC.md` for design decisions and how a feature works; `SECURITY.md` for anything read, written, sent or stored; `CONTRIBUTING.md` for the dev workflow.
   - A behavior, config, permission, file or network change with no matching doc update is **High** for `SECURITY.md` and **Medium** for `README.md` / `SPEC.md`. A doc that now contradicts the code is **Medium**.
   - UI changes include an updated screenshot when the README shows that screen (`scripts/screenshots.sh` renders them from sample data). A stale README screenshot is **Low**.
   - Use `N/A` only for tests-only, format-only, or a change no page describes.

6. **Language-specific rule compliance**
   - Open the skills the surface file names and check the diff against their concrete rules. Do not just link to them.
   - When a generic skill disagrees with ironpet's conventions (the table in `.agents/skills/swift/SKILL.md`, or `SPEC.md`), ironpet wins. Do not report a finding for following them.
   - A documented-rule violation is at least **Medium**. Safety, performance and correctness violations are **High** or **Critical**.

7. **Ownership and boundaries**
   - Every type has one responsibility, and the folder owners in `app.md` hold. Rules that can be unit-tested (approval policy, event mapping, config parsing, chunking, transcript layout) live in plain types, not in views or `AppDelegate`.
   - Prefer an existing primitive over a near-copy. A second copy of a control, rule, or helper is at least **Medium**.
   - If ownership is unclear, flag it as a high-priority architectural issue.
   - Record the outcome in the **Ownership / boundary check** table.

## Review output format

Produce, in this order:

1. **Findings by severity**: Critical, then High, then Medium, then Low. Every finding uses the shape below. A finding without a suggested fix is incomplete.
2. **If no issues**: state that no safety, privacy, maintainability, or ownership violations were found, then list residual risks or test gaps.
3. **The mandatory summary block** as the last thing in the review. Nothing follows it.

### Finding shape

Severity lives on the Issue line. Use only these four paragraphs, with a blank line between them.

```markdown
**Issue N (Critical | High | Medium | Low):** short title

**Area:** `path/to/file.swift:line` or symbol

**Why it matters:** one or two sentences on the user or system impact

**Suggested fix:** the local change for this finding
```

Suggested fix rules:

- Required. Local to this finding. Do not invent a second design. Do not implement the fix during review unless the author asks.
- Architecture findings name the owner, the current location, the destination, and the migration path.

| Severity | Suggested fix must be |
|---|---|
| Critical / High | Exact change: file, symbol, and what to write or revert |
| Medium | Expected location or pattern, plus a safe rename, move, or refactor path |
| Low | A one-line edit, or prefix with `optional:` |

### Review decision statuses

End the summary with exactly one of:

- **Approved**: no blocking issues in correctness, safety, privacy, maintainability, or ownership. Remaining comments are optional.
- **Approved with minor changes**: only non-blocking issues (readability, naming cleanup, minor refactors, docs or test polish). Low risk, localized, no behavior change required.
- **Must fix before merging**: blocking issues, including correctness bugs, safety or privacy risks, a feature on by default that touches the network or credentials, missing `SECURITY.md` coverage, boundary violations, unclear ownership, a hand-edited generated file, or failing gates.

Critical and High findings always require **Must fix before merging**. Medium findings require that status when they affect behavior, safety, ownership, or what the user is told. Localized non-blocking Medium and Low findings may use **Approved with minor changes**.

## Mandatory code review summary

End every review with a `## Code Review Summary` section containing the scope table, one gates table per touched surface, the **Always** table, the ownership table, and the residual-risks table.

- The scope table lists every surface. Untouched surfaces read `Not touched`, and their gates table is omitted.
- A touched surface's gates table copies the rows from its surface file. Every row is present. Use `N/A — <reason>` when a gate does not apply, and `⚠️ Skipped — <reason>` when it should have run but could not.
- Result cells are one visual mark (`✅`, `❌`, `⚠️`, or `N/A`) plus a short reason, and a count when the tool reports one.
- The language-guidelines row names the skills opened. If a skill was not consulted, say so.
- The docs row names the files checked. Missing or stale docs are not `✅`.

After the tables, list **Blockers fixed during review** when any were fixed, and **Non-blocking polish applied** when any was applied. Omit empty optional subsections. End with the **Final status** line and nothing after it.

### Template

```markdown
## Code Review Summary

### Scope
| Surface | Touched | Surface file |
|---|---|---|
| App | ✅ 4 files in `Sources/IronPet/Chat/ACP`, 1 test | `app.md` |
| Tooling | Not touched | — |
| Docs | ✅ `SECURITY.md` | — |

### App
| Check | Result |
|---|---|
| <rows from app.md> | |

### Always
| Check | Result |
|---|---|
| Safety | ✅ Hooks unchanged; `ApprovalRules` only adds a read-only verb, covered by `ApprovalRulesTests` |
| Privacy and defaults | ✅ New integration defaults to off; permission asked on first use |
| Secrets and config | ✅ Key in the Keychain; new `config.json` key documented in README |
| Structure/naming | ✅ New type in `Chat/ACP/`, file named after it |
| Docs | ✅ Checked `README.md`, `SPEC.md`, `SECURITY.md`; behavior matches |
| Language guidelines compliance | ✅ Opened `swift`, `swift-concurrency`, `swift-codable` |

### Ownership / boundary check
| Check | Result |
|---|---|
| Owner / placement | ✅ Lives in the folder that owns the area |
| Single responsibility | ✅ |
| Testable rules out of views | ✅ Policy in a plain type with unit tests |
| Main-thread and isolation | ✅ UI on the main actor; I/O off it |
| No parallel structure | ✅ Extends the existing type |
| Generated files | N/A — no generated file touched |

### Residual risks
| Risk | Status |
|---|---|
| Local verification commands | ✅ Ran the applicable gates |
| Installed-app check | ⚠️ Not run — needs `install.sh` (hotkeys, Screen Recording, notifications only behave from `/Applications`) |
| e2e scenarios | ⚠️ Not run — `cursor`, `claude`, `auto` cover this change; they use agent quota |
| Changes to the user's machine | ✅ None performed |

**Final status: <Approved | Approved with minor changes | Must fix before merging>**
```
