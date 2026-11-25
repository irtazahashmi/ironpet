#!/bin/bash
# Builds build/IronPet.app (release, ad-hoc signed).
# The bundle's version is the VERSION file at the repo root, unless IRONPET_VERSION overrides it (release_mac.sh does).
# IRONPET_BUILD sets the build number. IRONPET_HARDENED=1 signs with the hardened runtime and Resources/IronPet.entitlements,
# which notarization needs.
# Self-update (Sparkle): IRONPET_SPARKLE_PUBLIC_KEY is the EdDSA public key from `generate_keys` (CONTRIBUTING.md > Releasing the
# Mac app). Without it the build has no SUPublicEDKey, and the app turns updates off and says why. The framework is copied
# into Contents/Frameworks either way, so the binary always finds it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${IRONPET_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${IRONPET_BUILD:-1}"
# The short commit goes into Info.plist as IronPetGitCommit. IRONPET_DEV=1 (scripts/install.sh sets it) marks a local build.
COMMIT="${IRONPET_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || true)}"
DEV_PLIST=""
if [ "${IRONPET_DEV:-}" = "1" ]; then DEV_PLIST="<key>IronPetDevBuild</key><true/>"; fi
SPARKLE_KEY="${IRONPET_SPARKLE_PUBLIC_KEY:-}"
# These go into a plist, so keep them to characters that cannot break out of it. A base64 key adds + / =.
case "$VERSION$BUILD$COMMIT$SPARKLE_KEY" in
  *[!0-9A-Za-z.+/=-]*) echo "error: IRONPET_VERSION, IRONPET_BUILD, IRONPET_COMMIT and IRONPET_SPARKLE_PUBLIC_KEY may only contain letters, digits and . + - / =" >&2; exit 1 ;;
esac

swift build -c release
APP=build/IronPet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/IronPet" "$APP/Contents/MacOS/IronPet"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sparkle ships as a binary framework in the SwiftPM artifacts. The executable finds it through the @rpath entry added here.
SPARKLE_FRAMEWORK=$(find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -type d | sed -n 1p)
if [ -z "$SPARKLE_FRAMEWORK" ]; then echo "error: Sparkle.framework is not in .build/artifacts; run swift build first" >&2; exit 1; fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
# The app is not sandboxed, so Sparkle's XPC services (which only a sandboxed app needs) stay out of the bundle.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/IronPet"
# The database schema this build reaches, so the updater can refuse a "newer" build whose data is older (UpdatePolicy).
SCHEMA=$("$APP/Contents/MacOS/IronPet" --schema-version)
case "$SCHEMA" in ''|*[!0-9]*) echo "error: IronPet --schema-version printed '$SCHEMA'" >&2; exit 1 ;; esac
SPARKLE_PLIST=""
if [ -n "$SPARKLE_KEY" ]; then
  SPARKLE_PLIST="<key>SUPublicEDKey</key><string>$SPARKLE_KEY</string>"
else
  echo "warning: IRONPET_SPARKLE_PUBLIC_KEY is not set; this build has no update signing key and will not update itself" >&2
fi
# Mermaid diagrams in the chat: a pinned mermaid.js (scripts/fetch_mermaid.sh, shared with the iPhone app). Without
# network the app still builds; diagrams then show as code.
MERMAID_JS=$(./scripts/fetch_mermaid.sh)
if [ -n "$MERMAID_JS" ]; then
  cp "$MERMAID_JS" "$APP/Contents/Resources/mermaid.min.js"
  cp Resources/mermaid.html "$APP/Contents/Resources/mermaid.html"
fi
# ACP adapters for Claude Code, Codex and Pi: one self-contained .mjs per adapter (no node_modules, no agent binaries),
# run on the user's Node 22+ or a Bun they allow ironpet to download. Building needs Bun here, not on the user's Mac.
# `--omit=optional` keeps the agents' own platform binaries out of the install.
if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to bundle the ACP adapters (https://bun.sh)" >&2
  exit 1
fi
(
  cd sidecar
  npm ci --omit=optional --ignore-scripts --no-audit --no-fund >/dev/null
  rm -rf out
  for adapter in claude codex pi; do
    bun build --minify --target=node --format=esm "$adapter.mjs" --outfile "out/$adapter.mjs" >/dev/null
  done
)
mkdir -p "$APP/Contents/Resources/acp"
cp sidecar/out/claude.mjs sidecar/out/codex.mjs sidecar/out/pi.mjs "$APP/Contents/Resources/acp/"
# The pets are drawn in code. Ghost is the default sheet; all six fill the gallery in Settings. The generator itself
# ships too, for the ironpet-pets skill to copy and adapt.
mkdir -p "$APP/Contents/Resources/pets"
for pet in ghost mochi hamster panda bunny cat; do
  swift tools/make_pet.swift "$pet" "$APP/Contents/Resources/pets/$pet.png" >/dev/null
done
cp "$APP/Contents/Resources/pets/ghost.png" "$APP/Contents/Resources/spritesheet.png"
cp tools/make_pet.swift "$APP/Contents/Resources/make_pet.swift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ironpet.app</string>
  <key>CFBundleName</key><string>ironpet</string>
  <key>CFBundleDisplayName</key><string>ironpet</string>
  <key>CFBundleExecutable</key><string>IronPet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>@VERSION@</string>
  <key>CFBundleVersion</key><string>@BUILD@</string>
  <key>IronPetGitCommit</key><string>@COMMIT@</string>
  <key>IronPetSchemaVersion</key><string>@SCHEMA@</string>
  <key>SUFeedURL</key><string>https://github.com/irtazahashmi/ironpet/releases/latest/download/appcast.xml</string>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  @SPARKLE@
  @DEV@
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ironpet switches to the iTerm tab where an agent is waiting.</string>
  <key>NSMicrophoneUsageDescription</key><string>ironpet records your voice when you start a voice note, and sends it to the transcription server you set in Settings.</string>
  <key>NSScreenCaptureUsageDescription</key><string>ironpet captures a window or region when you ask it for help with your screen, the audio of the app you pick when you start a meeting transcript, and, only with Screen capture on, small header strips of an app such as Viber, read as text on this Mac.</string>
</dict>
</plist>
PLIST
sed -i '' "s/@VERSION@/$VERSION/; s/@BUILD@/$BUILD/; s/@COMMIT@/$COMMIT/; s/@SCHEMA@/$SCHEMA/; s|@DEV@|$DEV_PLIST|; s|@SPARKLE@|$SPARKLE_PLIST|" "$APP/Contents/Info.plist"

# IRONPET_SIGN_IDENTITY=- forces ad-hoc signing, e.g. when the keychain would prompt for the ironpet-dev key.
IDENTITY="${IRONPET_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  if security find-identity -p codesigning 2>/dev/null | grep -q '"ironpet-dev"'; then IDENTITY="ironpet-dev"; fi
fi
# Sparkle's code is signed from the inside out with the same identity as the app, never with --deep: its updater must carry the
# same Developer ID as the app it replaces, or the installed update would not launch.
SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ "${IRONPET_HARDENED:-}" = "1" ]; then
  # A secure timestamp from Apple's server is part of what notarization checks, so this needs network.
  for nested in "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$nested"
  done
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements Resources/IronPet.entitlements "$APP"
else
  for nested in "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$nested"
  done
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
fi
echo "Built $APP"
