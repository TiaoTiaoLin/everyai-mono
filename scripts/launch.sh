#!/usr/bin/env bash
# Runs or builds the EveryAI app against the deployed dev backend. Unlike
# scripts/dev.sh it never starts a local backend: the app talks to
# EVERYAI_API (default: the dev server below), and waits while it wakes up.
#
#   scripts/launch.sh                  this computer's app (macOS, Linux or Windows via Git Bash)
#   scripts/launch.sh web              Chrome on http://localhost:5173
#   scripts/launch.sh ios-sim          iOS Simulator (boots one if none is running)
#   scripts/launch.sh ios              the first connected iPhone
#   scripts/launch.sh android          the first Android device, else the first emulator
#   scripts/launch.sh <device-id>      any `flutter devices` id
#   scripts/launch.sh build [target]   an unsigned release build instead of a run (macos, linux, windows, web, apk)
#   scripts/launch.sh macos -- --release    extra args after -- go to `flutter run` / `flutter build`
#
# Missing Flutter is installed with Homebrew on macOS (and snap on Linux);
# CocoaPods too on macOS. Dependencies are fetched every time (fast when nothing changed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND="$ROOT/frontend"
DEV="$ROOT/.dev"
API="${EVERYAI_API:-https://everyai.136-108-68-64.sslip.io:8443}"
mkdir -p "$DEV"

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux) OS=linux ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac

MODE=run
if [[ "${1:-}" == build ]]; then
  MODE=build
  shift
fi
TARGET="${1:-$OS}"
[[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift
EXTRA=("$@")

# --- Flutter --------------------------------------------------------------
if ! command -v flutter >/dev/null; then
  case "$OS" in
    macos)
      command -v brew >/dev/null || die "Flutter and Homebrew are missing. Install Homebrew (https://brew.sh), then rerun."
      say "Installing Flutter with Homebrew"
      brew install --cask flutter
      ;;
    linux)
      command -v snap >/dev/null || die "Flutter is missing. Install it (https://docs.flutter.dev/get-started/install/linux), then rerun."
      say "Installing Flutter with snap"
      sudo snap install flutter --classic
      ;;
    windows) die "Flutter is missing. Install it (https://docs.flutter.dev/get-started/install/windows), then rerun." ;;
  esac
  command -v flutter >/dev/null || die "Flutter was installed but isn't on PATH yet. Open a new terminal and rerun."
fi
say "$(flutter --version 2>/dev/null | head -1)"

if [[ "$OS" == macos && ( "$TARGET" == macos || "$TARGET" == ios* ) ]]; then
  xcodebuild -version >/dev/null 2>&1 || die "Xcode is missing: install it from the App Store, then run: sudo xcodebuild -runFirstLaunch"
  if ! command -v pod >/dev/null; then
    say "Installing CocoaPods with Homebrew"
    brew install cocoapods
  fi
fi

say "Fetching dependencies"
(cd "$FRONTEND" && flutter pub get >/dev/null)

# --- where the app finds the backend --------------------------------------
DEFINES="$DEV/defines-launch.json"
cat >"$DEFINES" <<EOF
{
  "API_BASE_URL": "$API",
  "DEV_SKIP_AUTH": true,
  "SSE_ENABLED": true,
  "GOOGLE_SERVER_CLIENT_ID": ""
}
EOF
say "Backend: $API"
curl -sf -m 10 "$API/v1/ping" >/dev/null 2>&1 || say "The backend didn't answer yet; the app waits for it."

ARGS=(--dart-define-from-file="$DEFINES")
# Code's run_script sandbox (macOS only today).
if [[ "$TARGET" == macos && "$OS" == macos ]]; then
  if DENO="$("$FRONTEND/tool/fetch_deno.sh" | tail -1)"; then
    [[ "$MODE" == run ]] && ARGS+=(--dart-define=DENO_BIN="$DENO")
  else
    say "No Deno: run_script is off"
  fi
fi

# --- build ----------------------------------------------------------------
if [[ "$MODE" == build ]]; then
  cd "$FRONTEND"
  case "$TARGET" in
    macos) flutter build macos --release "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"; OUT="build/macos/Build/Products/Release/EveryAI.app" ;;
    linux) flutter build linux --release "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"; OUT="build/linux/x64/release/bundle" ;;
    windows) flutter build windows --release "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"; OUT="build/windows/x64/runner/Release" ;;
    web) flutter build web --release "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"; OUT="build/web" ;;
    apk | android) flutter build apk --release "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"; OUT="build/app/outputs/flutter-apk/app-release.apk" ;;
    *) die "Can't build '$TARGET' here: use macos, linux, windows, web or apk." ;;
  esac
  say "Built (unsigned, 0.1.0-dev-nonsigned): frontend/$OUT"
  [[ "$TARGET" == macos ]] && say "Open it: open \"frontend/$OUT\""
  exit 0
fi

# --- run ------------------------------------------------------------------
DEVICE=""
devices_json() { (cd "$FRONTEND" && flutter devices --machine 2>/dev/null); }
case "$TARGET" in
  macos | linux | windows) DEVICE="$TARGET" ;;
  web | chrome) DEVICE=chrome; ARGS+=(--web-port=5173) ;;
  ios-sim)
    [[ "$OS" == macos ]] || die "The iOS Simulator needs a Mac."
    DEVICE="$(xcrun simctl list devices -j | python3 -c '
import json,re,sys
devs = json.load(sys.stdin)["devices"]
def ver(rt): return [int(n) for n in re.findall(r"\d+", rt.split("iOS")[-1])] if "iOS" in rt else [-1]
booted = [d for rt in devs.values() for d in rt if d["state"] == "Booted" and ("iPhone" in d["name"] or "iPad" in d["name"])]
pick = booted[0] if booted else next((d for rt in sorted(devs, key=ver, reverse=True) if "iOS" in rt
                                      for d in devs[rt] if d.get("isAvailable") and d["name"].startswith("iPhone")), None)
if pick: print(pick["udid"], pick["state"], pick["name"], sep="\t")')"
    [[ -n "$DEVICE" ]] || die "No iPhone simulator installed (Xcode → Settings → Components)."
    IFS=$'\t' read -r DEVICE SIM_STATE SIM_NAME <<<"$DEVICE"
    if [[ "$SIM_STATE" != Booted ]]; then
      say "Booting $SIM_NAME"
      xcrun simctl boot "$DEVICE" 2>/dev/null || true
    fi
    xcrun simctl bootstatus "$DEVICE" -b >/dev/null || die "Simulator $SIM_NAME didn't boot."
    open -g -a Simulator --args -CurrentDeviceUDID "$DEVICE" 2>/dev/null || true
    say "Simulator: $SIM_NAME"
    ;;
  ios)
    DEVICE="$(devices_json | python3 -c '
import json,sys
for d in json.load(sys.stdin):
    if d.get("targetPlatform","").startswith("ios") and not d.get("emulator"): print(d["id"]); break')"
    [[ -n "$DEVICE" ]] || die "No iPhone connected (USB, or the same Wi-Fi with Developer Mode on)."
    ;;
  android)
    DEVICE="$(devices_json | python3 -c '
import json,sys
for d in json.load(sys.stdin):
    if d.get("targetPlatform","").startswith("android"): print(d["id"]); break')"
    if [[ -z "$DEVICE" ]]; then
      EMU="$(cd "$FRONTEND" && flutter emulators 2>/dev/null | awk -F'•' '/android/ {gsub(/ /,"",$1); print $1; exit}')"
      [[ -n "$EMU" ]] || die "No Android device or emulator (create one in Android Studio → Device Manager)."
      say "Starting emulator $EMU"
      (cd "$FRONTEND" && flutter emulators --launch "$EMU")
      for _ in $(seq 1 60); do
        DEVICE="$(devices_json | python3 -c '
import json,sys
for d in json.load(sys.stdin):
    if d.get("targetPlatform","").startswith("android"): print(d["id"]); break')"
        [[ -n "$DEVICE" ]] && break
        sleep 2
      done
      [[ -n "$DEVICE" ]] || die "The emulator didn't come up."
    fi
    ;;
  *) DEVICE="$TARGET" ;;
esac

say "flutter run -d $DEVICE ${ARGS[*]} ${EXTRA[*]:-}"
cd "$FRONTEND"
flutter run -d "$DEVICE" "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"
