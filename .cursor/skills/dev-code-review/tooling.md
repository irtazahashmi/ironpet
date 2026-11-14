# Tooling review — `sidecar/`, `scripts/`, `tools/`, `Resources/`, `.github/`

Everything that builds, installs, tests, or packages the app. These files run on contributors' and users' Macs with their permissions, so install, uninstall and download changes are reviewed for safety first.

## Layout and ownership

| Path | Owns | Edited by |
|---|---|---|
| `sidecar/claude.mjs`, `codex.mjs`, `pi.mjs` | Entry points of the ACP adapters for Claude Code, Codex and Pi | Hand |
| `sidecar/package.json`, `package-lock.json` | Pinned adapter versions (`@agentclientprotocol/claude-agent-acp`, `codex-acp`, `pi-acp`) | Hand, with `npm install` updating the lockfile |
| `sidecar/out/`, `sidecar/node_modules/` | Bundled `.mjs` output and dependencies | `scripts/bundle.sh` only; gitignored |
| `scripts/bundle.sh` | Release build of `build/IronPet.app`: binary, icon, pinned mermaid, adapters (`bun build`), sprite sheet, ad-hoc signing | Hand |
| `scripts/install.sh` | Preflight checks, signing identity, bundle, install to `/Applications`, restart | Hand |
| `scripts/uninstall.sh` | Removes hooks (through the binary's `--uninstall`), login item, app, Keychain items, preferences; asks before `~/.ironpet` and the identity | Hand |
| `scripts/make_signing_identity.sh` | The local self-signed `ironpet-dev` identity | Hand |
| `scripts/check_adapters.sh` | Starts each bundled adapter with stubbed CLIs and checks it answers `initialize` | Hand |
| `scripts/e2e.py` | End-to-end scenarios against the installed app in `--test-mode` | Hand |
| `scripts/gen_agent_catalog.py` | Writes `Sources/IronPet/Chat/ACP/AgentCatalogData.swift` from the ACP registry | Hand |
| `scripts/screenshots.sh` | Renders the README screenshots from sample data (`--render-previews`) | Hand |
| `scripts/configure_sentry.sh` | Sentry host, org, projects and token (to the Keychain) | Hand |
| `tools/make_wolf.swift`, `make_icon.swift`, `preview_cells.swift` | Ghost's sprite sheet and the app icon, drawn in code | Hand |
| `Resources/` | App icon, `mermaid.html` | Hand (`icon-1024.png` and `AppIcon.icns` from `make_icon.swift`) |
| `.github/workflows/ci.yml`, `.github/ISSUE_TEMPLATE/` | CI and issue templates | Hand |

## Rules to check

- **Adapters.** Versions in `sidecar/package.json` are exact pins, and `package-lock.json` changes with them. A dependency change without a lockfile change, a range instead of a pin, or a second package manager's lockfile is **High**. The adapters drive the user's own CLI (`CLAUDE_CODE_EXECUTABLE`, `CODEX_PATH`, `PI_ACP_PI_COMMAND`); the bundle contains no agent and no JavaScript runtime. Bundling one is **High**.
- **Downloads.** Anything fetched at build or run time is pinned to a version and checked against a SHA-256 before use, as the mermaid bundle in `bundle.sh` and the Bun download are. An unverified download that ends up executed or bundled is **Critical**. A build that fails without network when it could degrade (mermaid falls back to showing code) is **Medium**.
- **Install.** `install.sh` checks requirements and says how to fix what is missing, never installs system packages on its own, and creates the signing identity only when it is missing. Anything that writes outside the app bundle, `~/.ironpet` and the login Keychain identity is **High** and needs a `SECURITY.md` line.
- **Uninstall symmetry.** Everything install or the app creates is removed by `uninstall.sh` (or listed as kept on purpose, like `*.ironpet-backup`). It asks before deleting `~/.ironpet` unless `--purge`. A new file, Keychain item or login item with no uninstall path is **High**.
- **Shell scripts.** `#!/bin/bash` with `set -euo pipefail` (or a stated reason, as `check_adapters.sh` gives for `-uo`), `cd "$(dirname "$0")/.."`, quoted variables. `rm -rf` only on paths built from fixed prefixes, never on an unchecked variable. An unguarded `rm -rf "$VAR"` is **Critical**.
- **e2e.** A scenario restores every file it changes (`config.json`, hook files, setup state) even on failure, drives the app through `/test/*` or the accessibility tree rather than private state, and is registered in `SCENARIOS`. A scenario that needs extra services or spends a lot of agent quota goes in `OPT_IN`. A scenario that can leave the user's config or hooks changed is **High**.
- **Generators.** `gen_agent_catalog.py` output is committed together with any change to the script, and the generated file keeps its `Do not edit by hand` header. Sprite changes are made in `tools/make_wolf.swift`, and `bundle.sh` still writes `Contents/Resources/spritesheet.png` (CI checks it exists).
- **CI.** The workflow keeps `permissions: contents: read`, pinned toolchain versions (Node 22, Bun), `swift build`, `swift test`, the bundle with `codesign --verify` and `check_adapters.sh`, and the script syntax checks. Removing a gate is **High** unless the PR says why.

## Skills to open

- Swift files under `tools/`: `.agents/skills/swift/SKILL.md` and `swift-language`.
- Icon or sprite changes: `.agents/skills/apple-design/SKILL.md` with `app-icons.md`.
- There is no vendored shell, Python or Node skill. Review those against the rules above and the surrounding scripts.

## Gates

From the repo root:

```bash
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m py_compile scripts/e2e.py scripts/gen_agent_catalog.py
./scripts/bundle.sh                              # when sidecar/, tools/, Resources/ or bundle.sh changed
./scripts/check_adapters.sh build/IronPet.app    # when the adapters or bundle.sh changed
```

If `shellcheck` is installed, run it on changed scripts and report new warnings as **Low** (it is not part of CI). Never run `install.sh`, `uninstall.sh`, `configure_sentry.sh` or `e2e.py` during a review without asking.

Summary rows for the **Tooling** table:

| Check | Result |
|---|---|
| Shell syntax | `bash -n` on every script |
| Python compile | `py_compile` on `e2e.py`, `gen_agent_catalog.py` |
| App bundle | `bundle.sh`, spritesheet present, `codesign --verify`, or `N/A — <reason>` |
| Adapters | `check_adapters.sh`; pins and lockfile in step |
| Downloads pinned and verified | or `N/A` |
| Install / uninstall symmetry | or `N/A` |
| e2e scenario hygiene | Restores files, registered, opt-in when expensive, or `N/A` |
| CI gates intact | or `N/A` |
