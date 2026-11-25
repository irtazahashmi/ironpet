#!/bin/bash
# Signs the update archive for Sparkle and writes dist/appcast.xml next to it.
# Usage: scripts/make_appcast.sh <IronPet-x.y.z.zip> [--notes-file FILE] [--out FILE] [--url-base URL]
#
# Reads the Sparkle EdDSA private key from SPARKLE_ED_PRIVATE_KEY (the base64 text that `generate_keys -x` writes) and hands it to
# sign_update on standard input, so it never appears in a process list. Without the variable the script prints a notice and exits 0
# without writing anything: an unsigned build stays as it is today, and the release workflow goes on.
#
# The version, build number, minimum macOS and database schema come from the app's own Info.plist inside the zip, so the feed
# cannot disagree with the binary. The enclosure URL is the release asset URL of the tag v<version> in GITHUB_REPOSITORY
# (default irtazahashmi/ironpet); --url-base replaces everything before the file name, for a test served from localhost. Release notes: with --notes-file the text is embedded; otherwise the item links to the release page,
# which shows whatever the maintainer wrote before publishing.
#
# It refuses to write a feed whose signing key does not match the SUPublicEDKey inside the zip's app, because an app would then
# reject every update it is offered.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP=""
NOTES_FILE=""
OUT=""
URL_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) NOTES_FILE="${2:?--notes-file needs a file}"; shift 2 ;;
    --out) OUT="${2:?--out needs a file}"; shift 2 ;;
    --url-base) URL_BASE="${2:?--url-base needs a URL}"; shift 2 ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *) ZIP="$1"; shift ;;
  esac
done
if [ -z "$ZIP" ]; then echo "usage: scripts/make_appcast.sh <IronPet-x.y.z.zip> [--notes-file FILE] [--out FILE] [--url-base URL]" >&2; exit 2; fi
if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  echo "::notice::SPARKLE_ED_PRIVATE_KEY is not set, so no appcast.xml was made. This release will not reach installed apps by auto-update."
  exit 0
fi
if [ ! -f "$ZIP" ]; then echo "error: $ZIP does not exist" >&2; exit 1; fi
OUT="${OUT:-$(dirname "$ZIP")/appcast.xml}"
REPO="${GITHUB_REPOSITORY:-irtazahashmi/ironpet}"

SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$(find .build/artifacts -path '*/bin/sign_update' -type f | sed -n 1p)}"
if [ -z "$SIGN_UPDATE" ] || [ ! -x "$SIGN_UPDATE" ]; then
  echo "error: sign_update was not found in .build/artifacts; run swift package resolve first" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK"
APP=$(find "$WORK" -maxdepth 1 -name '*.app' -type d | sed -n 1p)
if [ -z "$APP" ]; then echo "error: $ZIP holds no .app" >&2; exit 1; fi
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MIN_OS=$(plist LSMinimumSystemVersion)
SCHEMA=$(plist IronPetSchemaVersion)
PUBLIC_KEY=$(plist SUPublicEDKey)
for pair in "CFBundleShortVersionString:$VERSION" "CFBundleVersion:$BUILD" "LSMinimumSystemVersion:$MIN_OS" "IronPetSchemaVersion:$SCHEMA" "SUPublicEDKey:$PUBLIC_KEY"; do
  if [ -z "${pair#*:}" ]; then echo "error: the app in $ZIP has no ${pair%%:*} in Info.plist" >&2; exit 1; fi
done
if [ "$(plist IronPetDevBuild)" = "true" ]; then echo "error: $ZIP holds a dev build; only releases go in the feed" >&2; exit 1; fi

# The signing key must be the pair of the key in the app. CryptoKit derives the public half (macOS's OpenSSL has no Ed25519).
DERIVED=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | swift tools/sparkle_public_key.swift) || {
  echo "error: SPARKLE_ED_PRIVATE_KEY is not the base64 of a 32-byte seed (generate_keys -x writes that format)" >&2
  exit 1
}
if [ "$DERIVED" != "$PUBLIC_KEY" ]; then
  echo "error: SPARKLE_ED_PRIVATE_KEY does not match the SUPublicEDKey in the app ($PUBLIC_KEY). Apps would reject this update." >&2
  echo "       Set IRONPET_SPARKLE_PUBLIC_KEY (the public key from generate_keys) to the pair of the private key, then rebuild." >&2
  exit 1
fi

SIGNATURE=$(printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$ZIP")
if [ -z "$SIGNATURE" ]; then echo "error: sign_update printed no signature" >&2; exit 1; fi
if ! printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify "$ZIP" "$SIGNATURE" >/dev/null; then
  echo "error: the signature does not verify against the archive" >&2
  exit 1
fi
LENGTH=$(stat -f %z "$ZIP")

export APPCAST_VERSION="$VERSION" APPCAST_BUILD="$BUILD" APPCAST_MIN_OS="$MIN_OS" APPCAST_SCHEMA="$SCHEMA"
export APPCAST_SIGNATURE="$SIGNATURE" APPCAST_LENGTH="$LENGTH" APPCAST_NOTES_FILE="$NOTES_FILE" APPCAST_OUT="$OUT"
URL_BASE="${URL_BASE:-https://github.com/$REPO/releases/download/v$VERSION}"
export APPCAST_URL="${URL_BASE%/}/$(basename "$ZIP")"
export APPCAST_PAGE="https://github.com/$REPO/releases/tag/v$VERSION"
export APPCAST_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
python3 -I - <<'PY'
import os
from xml.sax.saxutils import escape, quoteattr

e = os.environ
notes = ""
if e["APPCAST_NOTES_FILE"]:
    with open(e["APPCAST_NOTES_FILE"], encoding="utf-8") as f:
        text = f.read().strip()
    notes = f'      <description sparkle:format="plain-text">{escape(text)}</description>\n'
else:
    notes = f'      <sparkle:releaseNotesLink>{escape(e["APPCAST_PAGE"])}</sparkle:releaseNotesLink>\n'

xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:ironpet="urn:ironpet:appcast">
  <channel>
    <title>IronPet</title>
    <item>
      <title>IronPet {escape(e["APPCAST_VERSION"])}</title>
      <pubDate>{e["APPCAST_DATE"]}</pubDate>
      <sparkle:version>{escape(e["APPCAST_BUILD"])}</sparkle:version>
      <sparkle:shortVersionString>{escape(e["APPCAST_VERSION"])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(e["APPCAST_MIN_OS"])}</sparkle:minimumSystemVersion>
      <ironpet:schemaVersion>{escape(e["APPCAST_SCHEMA"])}</ironpet:schemaVersion>
{notes}      <enclosure url={quoteattr(e["APPCAST_URL"])} length={quoteattr(e["APPCAST_LENGTH"])} type="application/octet-stream" sparkle:edSignature={quoteattr(e["APPCAST_SIGNATURE"])}/>
    </item>
  </channel>
</rss>
'''
with open(e["APPCAST_OUT"], "w", encoding="utf-8") as f:
    f.write(xml)
PY
if command -v xmllint >/dev/null 2>&1; then xmllint --noout "$OUT"; fi
echo "Wrote $OUT for IronPet $VERSION (build $BUILD, schema $SCHEMA, $LENGTH bytes)"
