#!/bin/bash
# Archives IronPet Remote and uploads it to App Store Connect, where it shows up in TestFlight after processing.
# Signs with the Apple account signed in to Xcode (Settings > Accounts), which must belong to the team in iOS/project.yml,
# and needs the app record for dev.ironpet.app to exist in App Store Connect first.
# Usage: scripts/ios_testflight.sh [build-number]. The build number defaults to the UTC time, so each upload is higher.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${1:-$(date -u +%Y%m%d%H%M)}"
ARCHIVE="build/ios/IronPetRemote-$BUILD.xcarchive"
mkdir -p build/ios

(cd iOS && xcodegen generate -q)
xcodebuild archive -project iOS/IronPetRemote.xcodeproj -scheme IronPetRemote -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist iOS/ExportOptions.plist \
  -exportPath "build/ios/export-$BUILD" -allowProvisioningUpdates
echo "uploaded build $BUILD; it appears in TestFlight once App Store Connect finishes processing"
