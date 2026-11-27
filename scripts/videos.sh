#!/bin/bash
# Renders the website's clips in web/public/videos/ (an MP4 and a JPEG poster each) from made-up sample data, with the
# stock Ghost and Bunny sprites and default settings. Nothing from your own sessions, alerts, chats, memory or config.json
# ends up in them. The window clips open an ironpet window on screen while they record, so leave the Mac alone for a minute.
# Pass clip names to render only those: scripts/videos.sh chat agents
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-web/public/videos}"
mkdir -p build "$OUT"
swift build
swift tools/make_pet.swift ghost build/ghost-sheet.png >/dev/null
swift tools/make_pet.swift bunny build/bunny-sheet.png >/dev/null
only=()
if [ $# -gt 0 ]; then only=(--only "$(IFS=,; echo "$*")"); fi
.build/debug/IronPet --render-videos "$OUT" --sprite build/ghost-sheet.png --sprite-b build/bunny-sheet.png ${only[@]+"${only[@]}"}
