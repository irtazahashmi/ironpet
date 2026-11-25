#!/bin/bash
# Prints the path of the pinned mermaid.js, downloading it from npm on first use. The file is checked against its SHA-256
# and cached in build/vendor, so it is fetched once. Prints nothing and exits 0 when it cannot be fetched (offline):
# the Mac and iPhone apps then show diagrams as code.
set -euo pipefail
cd "$(dirname "$0")/.."
MERMAID_VERSION=12.2.0
MERMAID_SHA256=a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f
MERMAID_JS="build/vendor/mermaid-$MERMAID_VERSION.min.js"
if [ ! -f "$MERMAID_JS" ]; then
  mkdir -p build/vendor
  TMP=$(mktemp -d)
  if curl -fsSL "https://registry.npmjs.org/mermaid/-/mermaid-$MERMAID_VERSION.tgz" -o "$TMP/mermaid.tgz" \
     && tar -xzf "$TMP/mermaid.tgz" -C "$TMP" package/dist/mermaid.min.js \
     && [ "$(shasum -a 256 "$TMP/package/dist/mermaid.min.js" | cut -d' ' -f1)" = "$MERMAID_SHA256" ]; then
    mv "$TMP/package/dist/mermaid.min.js" "$MERMAID_JS"
  else
    echo "warning: could not fetch mermaid $MERMAID_VERSION; diagrams will show as code" >&2
  fi
  rm -rf "$TMP"
fi
if [ -f "$MERMAID_JS" ]; then echo "$PWD/$MERMAID_JS"; fi
