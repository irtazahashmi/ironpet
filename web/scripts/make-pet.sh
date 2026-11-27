#!/usr/bin/env bash
# Regenerates public/pet/ghost.webp from tools/make_pet.swift. Needs macOS (AppKit) and cwebp (brew install webp).
# The sheet is committed because the site builds on Linux, where the Swift generator cannot run.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swift tools/make_pet.swift ghost "$tmp/ghost.png"
cwebp -quiet -lossless -z 9 "$tmp/ghost.png" -o web/public/pet/ghost.webp
echo "wrote web/public/pet/ghost.webp"
