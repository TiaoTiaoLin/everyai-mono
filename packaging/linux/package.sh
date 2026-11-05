#!/usr/bin/env bash
# Linux release packages from a `flutter build linux --release` bundle:
#   EveryAI-<version>-x86_64.AppImage, everyai_<version>_amd64.deb, SHA256SUMS,
#   and (when GPG_KEY_ID is set) detached ASCII signatures (*.asc) for each.
#
#   packaging/linux/package.sh <bundle-dir> <version> [out-dir]
#
# Deno (the run_script sandbox) goes next to the `everyai` binary, where findDeno looks.
# Needs: dpkg-deb, curl, unzip, gpg (for signing). Linux x86_64 only for now.
# Signing env: GPG_KEY_ID (fingerprint), GPG_PASSPHRASE_FILE. The public key is packaging/linux/everyai-release-key.asc.
set -euo pipefail

BUNDLE="$(cd "${1:?bundle dir}" && pwd)"
VERSION="${2:?version}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$(mkdir -p "${3:-$ROOT/frontend/build/dist}" && cd "${3:-$ROOT/frontend/build/dist}" && pwd)"
APP_ID=dev.alidirect.everyai
APPIMAGETOOL_VERSION=1.9.1
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

[[ -x "$BUNDLE/everyai" ]] || { echo "no everyai binary in $BUNDLE" >&2; exit 1; }

say "Deno"
DENO="$("$ROOT/frontend/tool/fetch_deno.sh" | tail -1)"
cp -f "$DENO" "$BUNDLE/deno"; chmod 755 "$BUNDLE/deno"
cp -f "$ROOT/THIRD_PARTY_NOTICES.md" "$BUNDLE/THIRD_PARTY_NOTICES.md"
cp -f "$ROOT/LICENCE.md" "$ROOT/NOTICE" "$BUNDLE/"

desktop_file() { # $1 = Exec
  cat <<EOF
[Desktop Entry]
Type=Application
Name=EveryAI
Comment=Every AI model in one app: chat, research and coding agents
Exec=$1 %U
Icon=$APP_ID
Terminal=false
Categories=Development;
Keywords=AI;LLM;chat;agent;code;
StartupWMClass=$APP_ID
MimeType=x-scheme-handler/everyai;
EOF
}

install_icons() { # $1 = share dir
  local s
  for s in "$BUNDLE"/data/icons/hicolor/*/apps; do
    local size; size="$(basename "$(dirname "$s")")"
    mkdir -p "$1/icons/hicolor/$size/apps"
    for f in "$s"/everyai.*; do cp "$f" "$1/icons/hicolor/$size/apps/$APP_ID.${f##*.}"; done
  done
}

# --- .deb ------------------------------------------------------------------
say "Debian package"
DEB="$WORK/deb"
mkdir -p "$DEB/DEBIAN" "$DEB/opt/everyai" "$DEB/usr/bin" "$DEB/usr/share/applications"
cp -a "$BUNDLE/." "$DEB/opt/everyai/"
ln -s /opt/everyai/everyai "$DEB/usr/bin/everyai"
desktop_file /opt/everyai/everyai > "$DEB/usr/share/applications/$APP_ID.desktop"
install_icons "$DEB/usr/share"
SIZE="$(du -sk "$DEB" | cut -f1)"
cat > "$DEB/DEBIAN/control" <<EOF
Package: everyai
Version: ${VERSION//-/\~}
Section: devel
Priority: optional
Architecture: amd64
Maintainer: Ali Direct <xuckless@gmail.com>
Installed-Size: $SIZE
Depends: libgtk-3-0 | libgtk-3-0t64, libsecret-1-0, libc6 (>= 2.35)
Recommends: git
Homepage: https://github.com/xuckless/everyai-mono
Description: Every AI model in one app
 Chat, search, research and a coding workspace that drives EveryAI's own agent
 or the coding CLIs already installed (Claude Code, Codex, Gemini, OpenCode).
EOF
cat > "$DEB/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
EOF
chmod 755 "$DEB/DEBIAN/postinst"
DEB_OUT="$OUT/everyai_${VERSION}_amd64.deb"
dpkg-deb --root-owner-group --build "$DEB" "$DEB_OUT" >/dev/null

# --- AppImage --------------------------------------------------------------
say "AppImage"
APPDIR="$WORK/EveryAI.AppDir"
mkdir -p "$APPDIR/usr/share/applications"
cp -a "$BUNDLE/." "$APPDIR/"
desktop_file everyai > "$APPDIR/$APP_ID.desktop"
cp "$APPDIR/$APP_ID.desktop" "$APPDIR/usr/share/applications/"
install_icons "$APPDIR/usr/share"
cp "$BUNDLE/data/icons/hicolor/256x256/apps/everyai.png" "$APPDIR/$APP_ID.png"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/everyai" "$@"
EOF
chmod 755 "$APPDIR/AppRun"
TOOL="$WORK/appimagetool"
curl -fsSL -o "$TOOL" \
  "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-x86_64.AppImage"
chmod +x "$TOOL"
# Clear the AppImage magic bytes (ELF offset 8) so binfmt/QEMU (emulated amd64, Docker) can run it too.
printf '\0\0\0' | dd of="$TOOL" bs=1 seek=8 conv=notrunc 2>/dev/null
APPIMAGE_OUT="$OUT/EveryAI-$VERSION-x86_64.AppImage"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --no-appstream "$APPDIR" "$APPIMAGE_OUT" >/dev/null

# --- checksums + signatures --------------------------------------------------
say "Checksums"
(cd "$OUT" && sha256sum "$(basename "$DEB_OUT")" "$(basename "$APPIMAGE_OUT")" > SHA256SUMS)
if [[ -n "${GPG_KEY_ID:-}" ]]; then
  say "Signing with $GPG_KEY_ID"
  for f in "$DEB_OUT" "$APPIMAGE_OUT" "$OUT/SHA256SUMS"; do
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "${GPG_PASSPHRASE_FILE:?}" \
      --local-user "$GPG_KEY_ID" --armor --detach-sign --output "$f.asc" "$f"
  done
fi
ls -l "$OUT"
