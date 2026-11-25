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

`./scripts/ios_testflight.sh` archives the app and uploads it to TestFlight. On your Mac it signs with the Apple account signed in to Xcode, which must be on the team in `project.yml`; with `ASC_KEY_FILE`, `ASC_KEY_ID` and `ASC_ISSUER_ID` all set it signs with that App Store Connect API key instead, through Apple's cloud-managed signing, which is what the workflow below does. Either way it needs the `dev.ironpet.app` app to exist in App Store Connect. The App Group `group.dev.ironpet.app` must be enabled for the app and the widget extension on that team so the Home Screen widget can read the pet snapshot. Each upload needs a higher build number; the script uses the UTC time unless you pass one. The app icon comes from `swift tools/make_icon.swift <pet.png> iOS/IronPetRemote/Assets.xcassets/AppIcon.appiconset/icon-1024.png --ios`.

#### Uploading from GitHub

`.github/workflows/testflight.yml` does the same on a GitHub runner, so a build no longer needs one person's Mac. Open Actions → **TestFlight iOS** → Run workflow on `main`. The run waits for one of the reviewers of the `testflight` environment, then archives with Xcode 27.2 on GitHub's `xcode-27` runner image and uploads. App Store Connect requires the iOS 27 SDK from April 2027 (warning ITMS-90725 until then), which is why it is not the `macos-15` image that stops at Xcode 26; use a release Xcode, never a beta, and move the pin when Apple asks for a newer one. The build number is the UTC time, as in the script, so it is always above the earlier ones; a run number would be lower than the builds already uploaded and be rejected. The version is `MARKETING_VERSION` in `project.yml`. The job summary shows both, and the build appears in TestFlight once App Store Connect has processed it. It runs only from `main`, never for pull requests or tags.

It signs with an App Store Connect API key, so no certificate or provisioning profile is stored. Set this up once, before the first run:

- Create a **GitHub environment** named `testflight` (Settings → Environments → New environment). Under *Deployment branches and tags* choose *Selected branches and tags* and add the branch `main`, and add the maintainers who may ship a build under *Required reviewers* (the account holder and Aleksandar today; up to six). Anyone with write access can start a run, and any one of the reviewers can approve it, including the person who started it, so leave *Prevent self-review* off or a run started by the only person who can approve it cannot go ahead. `main` needs a pull request and the `build` check but no approving review, so the reviewers are the real gate: before approving a run, open its commit and check `testflight.yml`, `scripts/ios_testflight.sh` and `iOS/` for changes you did not expect, because the key can do more than upload builds. Add someone as a reviewer only if you would trust them with that key. Create it before the first run, because a workflow that names a missing environment creates it with no restrictions. The secrets go in this environment, not in the repository's own secrets, for the same reason as the Mac build: a repository secret reaches every workflow a collaborator pushes on any branch.
- Create an App Store Connect API key for iOS (App Store Connect → Users and Access → Integrations → Team Keys) with the **Admin** role, which cloud-managed distribution signing needs; if the first run fails with a signing error, a lower role is the likely cause. Keep it apart from the Mac notarization key, which only needs Developer. The `.p8` downloads only once.
- Add three secrets: `base64 -i AuthKey_XXXX.p8 | gh secret set ASC_KEY_P8 --env testflight`, then `gh secret set ASC_KEY_ID --env testflight` and `gh secret set ASC_ISSUER_ID --env testflight` (the issuer ID is shown above the keys).

### Releasing the Mac app

`.github/workflows/release.yml` (shown as **Release macOS** in the Actions tab) builds the Mac app and attaches a `.dmg` and its `.sha256` to a **draft** GitHub Release. Push a tag that is on `main` (`git tag v0.1.0 && git push origin v0.1.0`), or run the workflow from the Actions tab on `main` with a version (it refuses other branches, tags that are not on `main`, and a version whose tag already points at another commit). The build is Apple Silicon only, because GitHub's macOS runners are arm64. Then review the draft on the Releases page and publish it; publishing a draft that a manual run made creates the tag, and the run that tag starts skips itself. After publishing, bump the Homebrew cask by hand in [homebrew-ironpet](https://github.com/irtazahashmi/homebrew-ironpet) (its README lists the steps). The repository is public, so a published release is a public download. The version comes from the tag and the build number is the run number. The `VERSION` file at the repo root holds the version the app reports in dev builds too: bump it in a commit on `main` before tagging, and the workflow refuses any tag or input that does not match it. A published release is never rebuilt: bump the version instead.

Without secrets the build is signed ad hoc and named `IronPet-<version>-unsigned.dmg`. Once the certificate secret exists the workflow insists on a notarized build: a certificate that does not validate, or missing notary secrets, fail the run instead of quietly producing a weaker file. To sign and notarize it, the account holder first creates a GitHub **environment** named `release` (Settings → Environments → New environment), and under *Deployment branches and tags* chooses *Selected branches and tags* and adds the branch `main` and the tag pattern `v*`. The secrets go in that environment, not in the repository's own secrets: a repository secret reaches every workflow a collaborator pushes on any branch, whatever `release.yml` checks, while the environment admits only `main` and `v*` tags. That restriction alone is not enough: anyone with write access can push a `v*` tag on a commit that carries an edited `release.yml`, and that run would be admitted and could read the secrets. So **set up both of these before adding the first secret**:

- A tag ruleset (Settings → Rules → Rulesets → New tag ruleset): target `v*`, tick *Restrict creations*, *Restrict updates* and *Restrict deletions*, and add the *Write*, *Maintain* and *Admin* repository roles to the bypass list. Collaborators with write access can then push release tags; people without write cannot.
- A required reviewer on the `release` environment (Settings → Environments → release → Required reviewers), set to the account holder. Every run then waits for an approval, and the reviewer should open the run's commit and check `release.yml` and `scripts/` for changes before approving — that review is the real gate on the signing secrets, because write collaborators may create tags. Do not tick *Prevent self-review* while the account holder is the only reviewer, or the run cannot be approved.

Create the environment before the first run, because a workflow that names a missing environment creates it with no restrictions. Then add five secrets, each from a file with `base64 -i <file> | gh secret set <NAME> --env release` (or `gh secret set <NAME> --env release` for the plain ones):

- `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`: a **Developer ID Application** certificate. Create it in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application, then export it from Keychain Access as a `.p12` with a password.
- `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`: an App Store Connect API key with the Developer role or higher (App Store Connect → Users and Access → Integrations). The `.p8` downloads only once.

#### Auto-update keys (Sparkle)

Installed apps update themselves through [Sparkle](https://sparkle-project.org). Each release carries `IronPet-<version>.zip` and `appcast.xml` next to the DMG, and the app reads `https://github.com/irtazahashmi/ironpet/releases/latest/download/appcast.xml`. That URL resolves only to a **published** release, so a draft reaches nobody. Sparkle installs an update only if its EdDSA signature verifies against the public key inside the running app, so the key pair is created once and kept:

1. Make the pair on a Mac you trust: `swift package resolve`, then `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. It stores the private key in your login Keychain and prints the public key.
2. Export the private key to a file: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key`. The file holds the base64 of a 32-byte seed. Back it up in a password manager. Losing it means every installed app has to be reinstalled by hand once, because no update signed with a new key would verify.
3. Put the private key in the `release` environment as a secret: `gh secret set SPARKLE_ED_PRIVATE_KEY --env release < sparkle_private_key`. Then delete the file. The secret is only read by the "Sign the update and write appcast.xml" step.
4. Put the public key in the same environment as a **variable**, not a secret: `gh variable set SPARKLE_PUBLIC_ED_KEY --env release --body '<public key>'`. The build writes it into `Info.plist` as `SUPublicEDKey`. `scripts/make_appcast.sh` derives the public half of the private key and stops the run when it differs from the one in the app, so a mismatch fails the release instead of shipping updates no app accepts.

Do this before the first release you want installed apps to pick up. Apps built before the key existed have no `SUPublicEDKey` and cannot update themselves, so they need one manual install. Without the secret the appcast step prints a notice and the release is as before. Never commit the private key. Add the key and variable only after the tag ruleset and the required reviewer above are in place, because the secret is as sensitive as the signing certificate: whoever can sign an update can run code on every Mac that has the app.

Updates are checked once a day and downloaded in the background. A downloaded update waits while an agent turn, a voice note or a meeting recording is running, and installs when they end or when the user clicks the badge on the pet (Settings → General → Updates has the switches and Check now). A build from `scripts/install.sh` never checks or installs. To try an update locally, build an older and a newer version with `IRONPET_SPARKLE_PUBLIC_KEY` set, make an appcast with `scripts/make_appcast.sh <zip> --url-base http://127.0.0.1:8000`, serve the folder, and start the older build with `IRONPET_APPCAST_URL=http://127.0.0.1:8000/appcast.xml` (a dev build honours this variable; a release build ignores it).

`./scripts/release_mac.sh <version> [build]` does the same on your Mac and writes to `dist/`, using the certificate in your login keychain and either `NOTARY_PROFILE` (saved with `xcrun notarytool store-credentials`) or the three `NOTARY_*` variables. It needs the toolchain the workflow uses, Xcode 16.4: a newer Swift links the app to libraries that macOS 14 and 15 lack, and the script stops with an error when it sees that (`IRONPET_ALLOW_NEW_TOOLCHAIN=1` lets it through for a file you will only run on macOS 26 or later, and the notes say so). Most of the time, let the workflow build it. Hardened runtime needs the entitlements in `Resources/IronPet.entitlements`; add one there when a new feature needs a protected resource such as the camera or calendars, or a notarized build loses it silently.

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
