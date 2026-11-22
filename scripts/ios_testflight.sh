#!/bin/bash
# Archives IronPet Remote and uploads it to App Store Connect, where it shows up in TestFlight after processing.
# Needs the app record for dev.ironpet.app to exist in App Store Connect first, and XcodeGen on PATH.
# Usage: scripts/ios_testflight.sh [build-number]. The build number is digits only and defaults to the UTC time, so each
# upload is higher than the one before. Keep that scheme: TestFlight rejects a build number that is not higher.
#
# Signing is Xcode's automatic signing for the team in iOS/project.yml, with one of two logins:
#   - On your Mac it uses the Apple account signed in to Xcode (Settings > Accounts), which must belong to that team.
#   - With an App Store Connect API key it needs no Xcode account, and Apple's cloud-managed signing creates the
#     distribution certificate and profiles. Set all three (the workflow in .github/workflows/testflight.yml does):
#       ASC_KEY_FILE    path to the AuthKey_XXXX.p8 file
#       ASC_KEY_ID      the key's ID
#       ASC_ISSUER_ID   the issuer ID shown above the keys in App Store Connect
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${1:-$(date -u +%Y%m%d%H%M)}"
case "$BUILD" in
  '' | *[!0-9]*) echo "error: the build number must be digits only, got '$BUILD'" >&2; exit 1 ;;
esac

# All three variables or none: a half-set key would quietly fall back to whatever Xcode is signed in to.
SET=0
for name in ASC_KEY_FILE ASC_KEY_ID ASC_ISSUER_ID; do
  if [ -n "${!name:-}" ]; then SET=$((SET + 1)); fi
done
AUTH=()
if [ "$SET" -eq 3 ]; then
  [ -s "$ASC_KEY_FILE" ] || { echo "error: ASC_KEY_FILE '$ASC_KEY_FILE' is missing or empty" >&2; exit 1; }
  AUTH=(-authenticationKeyPath "$ASC_KEY_FILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
elif [ "$SET" -ne 0 ]; then
  echo "error: set ASC_KEY_FILE, ASC_KEY_ID and ASC_ISSUER_ID together, or none of them" >&2
  exit 1
fi

ARCHIVE="build/ios/IronPetRemote-$BUILD.xcarchive"
mkdir -p build/ios

(cd iOS && xcodegen generate -q)
# ${AUTH[@]+...} because macOS's bash 3.2 treats an empty array as unset under `set -u`.
xcodebuild archive -project iOS/IronPetRemote.xcodeproj -scheme IronPetRemote -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  ${AUTH[@]+"${AUTH[@]}"} CURRENT_PROJECT_VERSION="$BUILD"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist iOS/ExportOptions.plist \
  -exportPath "build/ios/export-$BUILD" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}
echo "uploaded build $BUILD; it appears in TestFlight once App Store Connect finishes processing"
