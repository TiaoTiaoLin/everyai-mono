#!/usr/bin/env bash
# Downloads the pinned Deno (the run_script sandbox) for this machine into
# frontend/.deno/ and checks it against the release's .sha256sum.
set -euo pipefail
VERSION="${DENO_VERSION:-2.9.8}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/.deno"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) TARGET="aarch64-apple-darwin" ;;
  Darwin-x86_64) TARGET="x86_64-apple-darwin" ;;
  Linux-aarch64 | Linux-arm64) TARGET="aarch64-unknown-linux-gnu" ;;
  Linux-x86_64) TARGET="x86_64-unknown-linux-gnu" ;;
  *) echo "No Deno build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
BIN="$DIR/deno"
if [[ -x "$BIN" && -f "$DIR/VERSION" && "$(cat "$DIR/VERSION")" == "$VERSION" ]]; then
  echo "$BIN"; exit 0
fi
mkdir -p "$DIR"
ASSET="deno-$TARGET.zip"
BASE="https://github.com/denoland/deno/releases/download/v$VERSION"
curl -fsSL -o "$DIR/$ASSET.sha256sum" "$BASE/$ASSET.sha256sum"
curl -fL --progress-bar -o "$DIR/$ASSET" "$BASE/$ASSET"
WANT="$(grep -oE '[0-9a-f]{64}' "$DIR/$ASSET.sha256sum" | head -1)"
GOT="$(shasum -a 256 "$DIR/$ASSET" | awk '{print $1}')"
if [[ -z "$WANT" || "$WANT" != "$GOT" ]]; then
  echo "Checksum mismatch for $ASSET (want $WANT, got $GOT)" >&2; rm -f "$DIR/$ASSET"; exit 1
fi
rm -f "$BIN"
unzip -q -o "$DIR/$ASSET" deno -d "$DIR"
rm -f "$DIR/$ASSET" "$DIR/$ASSET.sha256sum"
chmod +x "$BIN"
[[ "$(uname -s)" == Darwin ]] && xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
echo "$VERSION" > "$DIR/VERSION"
echo "$BIN"
