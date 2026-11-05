#!/bin/bash
# Signed macOS release: Developer ID signature (hardened runtime) → notarized, stapled DMG.
#
#   frontend/macos/scripts/release_macos.sh [path/to/EveryAI.app]
#
# Without an app path it builds one first (scripts/launch.sh build macos, which also bundles Deno).
# Output: frontend/build/dist/EveryAI-<version>.dmg (+ .sha256).
#
# Env (defaults fit the owner's Mac; CI sets them from secrets, see .github/workflows/release.yml):
#   SIGN_IDENTITY     codesign identity      (Developer ID Application: SYED SYED ALI (2MGLZ5685D))
#   PROVISION_PROFILE Developer ID profile   (~/.applesigning/everyai/EveryAI_Developer_ID.provisionprofile)
#   NOTARY_PROFILE    notarytool keychain profile (everyai-notary), or instead
#   ASC_KEY_PATH + ASC_KEY_ID + ASC_ISSUER_ID   an App Store Connect API key
#   SKIP_NOTARIZE=1   sign only (quick local check)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FRONTEND="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$FRONTEND/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: SYED SYED ALI (2MGLZ5685D)}"
PROVISION_PROFILE="${PROVISION_PROFILE:-$HOME/.applesigning/everyai/EveryAI_Developer_ID.provisionprofile}"
NOTARY_PROFILE="${NOTARY_PROFILE:-everyai-notary}"
ENTITLEMENTS="$FRONTEND/macos/Runner/DeveloperID.entitlements"
DENO_ENTITLEMENTS="$HERE/deno.entitlements"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$PROVISION_PROFILE" ]] || die "no provisioning profile at $PROVISION_PROFILE"
security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" || die "identity not in keychain: $SIGN_IDENTITY"

APP="${1:-}"
if [[ -z "$APP" ]]; then
  say "Building"
  "$ROOT/scripts/launch.sh" build macos
  APP="$FRONTEND/build/macos/Build/Products/Release/EveryAI.app"
fi
[[ -d "$APP" ]] || die "no app at $APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
FULL_VERSION="$(grep -m1 '^version:' "$FRONTEND/pubspec.yaml" | sed 's/version: *//; s/+.*//')"

# Work on a copy, so the build folder keeps the plain build.
DIST="$FRONTEND/build/dist"
rm -rf "$DIST"; mkdir -p "$DIST"
STAGE="$DIST/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/EveryAI.app"
APP="$STAGE/EveryAI.app"

sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }

say "Signing nested code (inside out)"
# Every Mach-O except the main executable and Deno, deepest path first; then bundles.
while IFS= read -r f; do
  [[ "$f" == "$APP/Contents/MacOS/EveryAI" || "$f" == "$APP/Contents/Resources/deno" ]] && continue
  if file -b "$f" | grep -q 'Mach-O'; then sign "$f"; fi
done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
# Sparkle's XPC services keep their own entitlements.
while IFS= read -r b; do
  if [[ "$b" == *.xpc ]]; then sign --preserve-metadata=entitlements "$b"; else sign "$b"; fi
done < <(
  find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' -o -name '*.app' \) -type d)
# V8 compiles at run time: Deno keeps its JIT entitlements.
if [[ -f "$APP/Contents/Resources/deno" ]]; then
  sign --entitlements "$DENO_ENTITLEMENTS" "$APP/Contents/Resources/deno"
else
  say "warning: no bundled Deno (run_script will be off)"
fi

say "Signing the app"
cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

DMG="$DIST/EveryAI-$FULL_VERSION.dmg"
say "Making $(basename "$DMG")"
mkdir -p "$STAGE/dmg"
mv "$APP" "$STAGE/dmg/EveryAI.app"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -volname "EveryAI" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
sign "$DMG"

if [[ "${SKIP_NOTARIZE:-}" == 1 ]]; then
  say "Skipping notarization"
else
  say "Notarizing (a few minutes)"
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    AUTH=(--key "$ASC_KEY_PATH" --key-id "${ASC_KEY_ID:?}" --issuer "${ASC_ISSUER_ID:?}")
  else
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
  fi
  OUT="$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json)" || true
  echo "$OUT"
  ID="$(echo "$OUT" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if ! echo "$OUT" | grep -q '"status" *: *"Accepted"'; then
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
    die "notarization failed"
  fi
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
say "Done: $DMG ($VERSION build $BUILD)"
