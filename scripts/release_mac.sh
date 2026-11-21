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
elif [ -n "${NOTARY_KEY_FILE:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  NOTARY=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
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
if [ -n "$IDENTITY" ] && ! codesign -dv "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
  echo "error: the app is signed without the hardened runtime, so it cannot be notarized" >&2
  exit 1
fi

rm -rf dist build/dmg-staging
mkdir -p dist build/dmg-staging
ditto "$APP" build/dmg-staging/IronPet.app
ln -s /Applications build/dmg-staging/Applications
DMG="dist/$NAME.dmg"
hdiutil create -volname "IronPet" -srcfolder build/dmg-staging -ov -format UDZO "$DMG" >/dev/null
rm -rf build/dmg-staging

NOTARIZED=no
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  if [ ${#NOTARY[@]} -gt 0 ]; then
    echo "Notarizing $DMG (this usually takes a few minutes)"
    RESULT=$(xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --output-format json)
    STATUS=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
    if [ "$STATUS" != "Accepted" ]; then
      ID=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
      echo "error: notarization finished with status '$STATUS'" >&2
      [ -n "$ID" ] && xcrun notarytool log "$ID" "${NOTARY[@]}" >&2 || true
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
    echo "**Unsigned build.** Open the DMG and drag IronPet to Applications. macOS blocks the first launch of an app that is not signed by a developer: right-click IronPet and choose Open, or run \`xattr -dr com.apple.quarantine /Applications/IronPet.app\`."
  fi
  echo
  echo "Check the download against \`$NAME.dmg.sha256\`: \`shasum -a 256 -c $NAME.dmg.sha256\`."
  echo
} > dist/notes.md

echo "Built $DMG (notarized: $NOTARIZED)"
