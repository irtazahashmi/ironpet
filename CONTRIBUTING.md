# Contributing

Thanks for helping out! Bug reports, ideas and pull requests are all welcome. For anything bigger than a small fix, please open an issue first so we can agree on the approach before you spend time on it.

## Setup

You need macOS 14+, the Xcode command line tools (Swift 5.10+; full Xcode with the macOS 27 SDK, since SwiftUI's macros ship only with Xcode), npm and Bun (to bundle the ACP adapters in `sidecar/`), and at least one agent CLI (for example `cursor-agent` or `claude`) to try the chat.

```bash
git clone https://github.com/irtazahashmi/ironpet.git
cd ironpet
./scripts/install.sh      # build, install to /Applications and start
```

The [README](README.md) covers features and configuration, [SPEC.md](SPEC.md) the design and the reasons behind it, and [SECURITY.md](SECURITY.md) what the app reads and writes.

## Making changes

```bash
swift build               # debug build
swift test                # unit tests: config parsing, shortcuts, hook install/uninstall
# UI tests (windows, rendered views, scroll layout) skip when CI is set, so they run here, not on CI:
# run them locally before merging chat, window or settings changes.
./scripts/install.sh      # release build, install, restart
./scripts/screenshots.sh  # render the README screenshots from sample data
```

Check your change in the installed app, not just with `swift build`. Things like global hotkeys, Screen Recording and notifications only behave properly from `/Applications/IronPet.app`, signed with the `ironpet-dev` identity that `install.sh` creates.

### iOS app

`iOS/project.yml` describes the Xcode project (app plus the `IronPetWidget` extension). `xcodegen generate` in `iOS/` writes it, and `xcodebuild test -project iOS/IronPetRemote.xcodeproj -scheme IronPetRemote -destination 'platform=iOS Simulator,name=iPhone 17'` runs the tests. The Mac side is tested by `swift test`, which also runs the IronPetKit tests.

`./scripts/ios_testflight.sh` archives the app and uploads it to TestFlight. It signs with the Apple account signed in to Xcode, which must be on the team in `project.yml`, and needs the `dev.ironpet.app` app to exist in App Store Connect. The App Group `group.dev.ironpet.app` must be enabled for the app and the widget extension on that team so the Home Screen widget can read the pet snapshot. Each upload needs a higher build number; the script uses the UTC time unless you pass one. The app icon comes from `swift tools/make_icon.swift <pet.png> iOS/IronPetRemote/Assets.xcassets/AppIcon.appiconset/icon-1024.png --ios`.

### Releasing the Mac app

`.github/workflows/release.yml` builds the Mac app and attaches a `.dmg` and its `.sha256` to a **draft** GitHub Release. Push a tag (`git tag v0.1.0 && git push origin v0.1.0`), or run the workflow from the Actions tab on `main` with a version (it refuses other branches, and a version whose tag already points at another commit). Then review the draft on the Releases page and publish it; publishing a draft that a manual run made creates the tag, and the run that tag starts skips itself. The repository is public, so a published release is a public download. The version comes from the tag and the build number is the run number. A published release is never rebuilt: bump the version instead.

Without secrets the build is signed ad hoc and named `IronPet-<version>-unsigned.dmg`. Once the certificate secret exists the workflow insists on a notarized build: a certificate that does not validate, or missing notary secrets, fail the run instead of quietly producing a weaker file. To sign and notarize it, the account holder adds five repository secrets, each from a file with `base64 -i <file> | gh secret set <NAME>` (or `gh secret set <NAME>` for the plain ones):

- `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`: a **Developer ID Application** certificate. Create it in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application, then export it from Keychain Access as a `.p12` with a password.
- `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`: an App Store Connect API key with the Developer role or higher (App Store Connect → Users and Access → Integrations). The `.p8` downloads only once.

`./scripts/release_mac.sh <version> [build]` does the same on your Mac and writes to `dist/`, using the certificate in your login keychain and either `NOTARY_PROFILE` (saved with `xcrun notarytool store-credentials`) or the three `NOTARY_*` variables. Hardened runtime needs the entitlements in `Resources/IronPet.entitlements`; add one there when a new feature needs a protected resource such as the camera or calendars, or a notarized build loses it silently.

### End-to-end tests

`python3 scripts/e2e.py [scenario ...]` relaunches the installed app with `--test-mode` and drives it through test-only endpoints and the real windows. Most scenarios run real `cursor-agent` and Claude Code turns, so they use your agent quota and need both signed in, with both agents turned on under Settings → General. The `setup` and `settings` scenarios click through the native windows using accessibility, so your terminal needs Accessibility permission and you shouldn't type while they run. Scenarios that change `config.json` or the hook files restore your copies afterwards.

Run the scenarios related to your change, and mention which ones you ran in the pull request. `mcp` and `sentry` only run when named, because they need a Langfuse or Sentry MCP signed in with `cursor-agent`.

## Guidelines

- **Safety first.** ironpet edits other tools' config files and starts agents that can change files. Changes to hooks, approvals, Auto mode or anything that writes outside `~/.ironpet` need tests and a note in SECURITY.md. New integrations that touch the network or credentials are off by default.
- **Settings** go in `Config` (`Support/Config.swift`) with a safe default, plus a control on a Settings page if most people would want to change them. Document new keys in the README's Configuration section.
- **Style.** Follow the code around your change. Keep functions small, comment the *why* rather than the *what*, and don't add dependencies without discussing it first.
- **Commits and PRs.** Keep each PR focused on one thing. Describe what changed, why, and how you tested it; include a screenshot for UI changes. CI picks jobs from the paths you touch: Mac build/test/bundle when `Sources/`, `Tests/`, `Package.swift`, adapters or related scripts change; iOS when `iOS/` or `IronPetKit` change; script syntax alone when only other files under `scripts/` change. Docs-only PRs (README, SPEC, SECURITY, …) skip those runners; the required `build` check still passes.

## Reporting bugs

Use the bug report template. Please leave tokens, chat contents and anything private out of issues. Report security problems privately (see [SECURITY.md](SECURITY.md)).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
