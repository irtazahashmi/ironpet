#!/bin/bash
# Builds the downloadable Mac app: dist/IronPet-<version>.dmg and its .sha256, plus dist/notes.md for the release.
# Usage: scripts/release_mac.sh <version> [build-number]     e.g. scripts/release_mac.sh 0.1.0 12
#
# With a "Developer ID Application" identity in a keychain on the search list, the app is signed with the hardened
# runtime and Resources/IronPet.entitlements. With notary credentials too, the DMG is notarized and stapled, so
# Gatekeeper opens it without a warning. Notary credentials are either
#   NOTARY_KEY_FILE (an App Store Connect API key, .p8) with NOTARY_KEY_ID and NOTARY_ISSUER_ID, or
#   NOTARY_PROFILE (a profile saved with `xcrun notarytool store-credentials`).
# Without an identity the app is signed ad hoc and the file is named IronPet-<version>-unsigned.dmg; it still works,
# but macOS blocks it until the user allows it (the notes say how).
# IRONPET_DEVELOPER_ID picks one identity by name when the keychain has several.
# IRONPET_REQUIRE_NOTARIZED=1 turns every downgrade into an error: no identity, or no notary credentials, stops the build
# instead of producing an unsigned or un-notarized file. The release workflow sets it whenever it imported a certificate.
# IRONPET_ALLOW_NEW_TOOLCHAIN=1 lets a build through whose executable needs a Swift library that macOS 14 and 15 lack
# (a toolchain newer than Xcode 16.4 does that); the notes then say it needs macOS 26 or later. Without it the script stops.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release_mac.sh <version> [build-number]}"
BUILD="${2:-1}"
APP=build/IronPet.app

IDENTITY="${IRONPET_DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | sed -n 1p)
fi

NOTARY=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
else
  given=0
  for value in "${NOTARY_KEY_FILE:-}" "${NOTARY_KEY_ID:-}" "${NOTARY_ISSUER_ID:-}"; do
    if [ -n "$value" ]; then given=$((given + 1)); fi
  done
  if [ "$given" -eq 3 ]; then
    NOTARY=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  elif [ "$given" -ne 0 ]; then
    echo "error: NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID go together; only $given of 3 are set" >&2
    exit 1
  fi
fi

if [ "${IRONPET_REQUIRE_NOTARIZED:-}" = "1" ]; then
  if [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' identity is usable (an expired or untrusted certificate is skipped)" >&2
    exit 1
  fi
  if [ ${#NOTARY[@]} -eq 0 ]; then
    echo "error: notary credentials are missing, so the build could not be notarized" >&2
    exit 1
  fi
fi

export IRONPET_VERSION="$VERSION" IRONPET_BUILD="$BUILD"
if [ -n "$IDENTITY" ]; then
  export IRONPET_SIGN_IDENTITY="$IDENTITY" IRONPET_HARDENED=1
  NAME="IronPet-$VERSION"
  echo "Signing with: $IDENTITY"
else
  # Ad hoc, not the local ironpet-dev identity: that certificate exists only on the author's Mac.
  export IRONPET_SIGN_IDENTITY=-
  NAME="IronPet-$VERSION-unsigned"
  echo "No Developer ID Application identity found: building an unsigned release"
fi

./scripts/bundle.sh
codesign --verify --strict --verbose=2 "$APP"
# Match in the shell, not with `codesign | grep -q`: grep exits at the first match, codesign then gets SIGPIPE, and
# pipefail reports the whole check as failed even though the flag is there.
if [ -n "$IDENTITY" ]; then
  details=$(codesign -dv "$APP" 2>&1)
  if [[ "$details" != *flags=*runtime* ]]; then
    echo "error: the app is signed without the hardened runtime, so it cannot be notarized" >&2
    exit 1
  fi
fi

# A newer Swift toolchain can link the executable to a back-deployment library through @rpath and leave the library out of
# the bundle (libswiftCompatibilitySpan from Swift 6.2 on). It runs on the Mac that built it and on macOS 26 and later,
# and fails to launch on the macOS 14 and 15 that Info.plist promises, so a download must not carry it.
LOOSE=$(otool -L "$APP/Contents/MacOS/IronPet" | awk 'NR > 1 {print $1}' | grep '^@rpath/' || true)
NEEDS_NEW_MACOS=no
if [ -n "$LOOSE" ]; then
  echo "The executable needs libraries that are not in the app:" >&2
  printf '%s\n' "$LOOSE" | sed 's/^/  /' >&2
  if [ "${IRONPET_ALLOW_NEW_TOOLCHAIN:-}" = "1" ]; then
    echo "warning: continuing because IRONPET_ALLOW_NEW_TOOLCHAIN=1; the notes will say it needs macOS 26 or later" >&2
    NEEDS_NEW_MACOS=yes
  else
    echo "error: this Swift toolchain is too new for the oldest macOS the app supports. Build with Xcode 16.4" >&2
    echo "(sudo xcode-select -s /Applications/Xcode_16.4.app), let the Release workflow build it, or set" >&2
    echo "IRONPET_ALLOW_NEW_TOOLCHAIN=1 for a file you will only run on macOS 26 or later." >&2
    exit 1
  fi
fi

# What the binary really runs on, for the notes. GitHub's macOS runners are Apple Silicon, so this is usually arm64 only.
ARCHS=$(lipo -archs "$APP/Contents/MacOS/IronPet")

rm -rf dist build/dmg-staging
mkdir -p dist build/dmg-staging
ditto "$APP" build/dmg-staging/IronPet.app
ln -s /Applications build/dmg-staging/Applications
DMG="dist/$NAME.dmg"
# hdiutil sometimes fails with "Resource busy" on a fresh runner, so try a few times.
for attempt in 1 2 3; do
  if hdiutil create -volname "IronPet" -srcfolder build/dmg-staging -ov -format UDZO "$DMG" >/dev/null; then break; fi
  if [ "$attempt" -eq 3 ]; then echo "error: hdiutil could not create the DMG" >&2; exit 1; fi
  sleep 5
done
rm -rf build/dmg-staging

NOTARIZED=no
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  if [ ${#NOTARY[@]} -gt 0 ]; then
    echo "Notarizing $DMG (this usually takes a few minutes)"
    # notarytool may exit non-zero for a rejected build, so read the verdict from its JSON instead of its exit code.
    RESULT=$(xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --timeout 30m --output-format json) || true
    field() { printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null || true; }
    STATUS=$(field status)
    if [ "$STATUS" != "Accepted" ]; then
      ID=$(field id)
      echo "error: notarization finished with status '${STATUS:-unknown}'" >&2
      printf '%s\n' "$RESULT" >&2
      if [ -n "$ID" ]; then xcrun notarytool log "$ID" "${NOTARY[@]}" >&2 || true; fi
      exit 1
    fi
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    NOTARIZED=yes
  else
    echo "warning: no notary credentials; the DMG is signed but not notarized, so Gatekeeper will still warn" >&2
  fi
fi
hdiutil verify "$DMG" >/dev/null

(cd dist && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

{
  if [ "$NOTARIZED" = yes ]; then
    echo "Open the DMG and drag IronPet to Applications. It is signed with a Developer ID and notarized by Apple."
  elif [ -n "$IDENTITY" ]; then
    echo "Open the DMG and drag IronPet to Applications. It is signed with a Developer ID but **not notarized**, so macOS asks you to confirm the first launch."
  else
    echo "**Unsigned build.** Open the DMG and drag IronPet to Applications. macOS blocks the first launch of an app that is not signed by a developer. On macOS 15 or later, open System Settings → Privacy & Security and click **Open Anyway** after the first attempt; on macOS 14, right-click IronPet and choose Open. Or run \`xattr -dr com.apple.quarantine /Applications/IronPet.app\`."
  fi
  echo
  if [ "$NEEDS_NEW_MACOS" = yes ]; then
    echo "**Needs macOS 26 or later.** It was built with a newer Swift toolchain than the release workflow uses."
    echo
  fi
  if [ "$ARCHS" = "arm64" ]; then
    echo "This build runs on **Apple Silicon Macs only**. On an Intel Mac, build from source with \`./scripts/install.sh\`."
  else
    echo "This build runs on: $ARCHS."
  fi
  echo
  echo "Check the download against \`$NAME.dmg.sha256\`: \`shasum -a 256 -c $NAME.dmg.sha256\`."
  echo
} > dist/notes.md

echo "Built $DMG (notarized: $NOTARIZED)"
