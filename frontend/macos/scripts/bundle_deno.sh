#!/bin/bash
# Xcode build phase (Runner): copies the pinned Deno (the run_script
# sandbox, see script_io.dart findDeno) into EveryAI.app/Contents/Resources,
# with our third-party notices. tool/fetch_deno.sh downloads and checks it
# once; later builds reuse frontend/.deno/.
set -euo pipefail

FRONTEND="${PROJECT_DIR:?run from Xcode}/.."
DEST="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources"

SRC="$("$FRONTEND/tool/fetch_deno.sh" | tail -1)"
if [[ ! -x "$SRC" ]]; then
  echo "error: Deno download failed (frontend/tool/fetch_deno.sh); run_script needs it." >&2
  exit 1
fi

mkdir -p "$DEST"
# Only when it changed: the binary is ~100 MB.
if ! cmp -s "$SRC" "$DEST/deno"; then
  cp -f "$SRC" "$DEST/deno"
  chmod 755 "$DEST/deno"
fi
cp -f "$FRONTEND/../THIRD_PARTY_NOTICES.md" "$DEST/THIRD_PARTY_NOTICES.md"

# Sign it like the app, so a signed build launches it. V8 compiles code at
# run time, which the hardened runtime needs allowed (deno.entitlements).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "$IDENTITY" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DEST/deno"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
      --entitlements "$PROJECT_DIR/scripts/deno.entitlements" "$DEST/deno"
  fi
fi
