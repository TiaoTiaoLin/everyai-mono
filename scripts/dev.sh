#!/usr/bin/env bash
# Runs backend-exp and the Flutter app together.
#
#   scripts/dev.sh                 macOS app (+ Deno for Code's run_script)
#   scripts/dev.sh web             Chrome on http://localhost:5173
#   scripts/dev.sh ios-sim         iOS Simulator (boots one if none is running)
#   scripts/dev.sh ios             the first connected iPhone (backend on the LAN)
#   scripts/dev.sh <device-id>     any `flutter devices` id
#   scripts/dev.sh macos -- --release    extra args after -- go to `flutter run`
#
# A backend already answering on :8080 is reused; otherwise one is started and
# stopped when the app exits. Logs: .dev/backend.log. Backend data:
# backend-exp/data/everyai.db (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND="$ROOT/frontend"
BACKEND="$ROOT/backend-exp"
DEV="$ROOT/.dev"
PORT="${PORT:-8080}"
mkdir -p "$DEV"

TARGET="${1:-macos}"
[[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift
EXTRA=("$@")

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# --- where the app should find the backend --------------------------------
HOST=127.0.0.1
DEV_AUTH_LAN=false
API="http://localhost:$PORT"
DEVICE=""
case "$TARGET" in
  macos) DEVICE=macos ;;
  web | chrome) DEVICE=chrome ;;
  ios-sim)
    # A booted iPhone/iPad wins; otherwise the iPhone on the newest iOS runtime.
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
    # The window app: Simulator.app up to Xcode 26, Device Hub from Xcode 27.
    XCODE_APPS="$(dirname "$(xcode-select -p)")/Applications"
    if [[ -d "$XCODE_APPS/Simulator.app" ]]; then
      open -g "$XCODE_APPS/Simulator.app" --args -CurrentDeviceUDID "$DEVICE"
    elif [[ -d "$XCODE_APPS/DeviceHub.app" ]]; then
      open -g "$XCODE_APPS/DeviceHub.app"
    else
      say "No simulator window app in this Xcode; $SIM_NAME runs headless (xcrun simctl io booted screenshot x.png)"
    fi
    say "Simulator: $SIM_NAME ($DEVICE)"
    ;;
  ios)
    DEVICE="$(cd "$FRONTEND" && flutter devices --machine 2>/dev/null | python3 -c '
import json,sys
for d in json.load(sys.stdin):
    if d.get("targetPlatform","").startswith("ios") and not d.get("emulator"): print(d["id"]); break')"
    [[ -n "$DEVICE" ]] || die "No iPhone connected (USB or same-Wi-Fi with Developer Mode on)."
    LAN="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)"
    [[ -n "$LAN" ]] || die "No LAN address found for the phone to reach the backend."
    HOST=0.0.0.0
    DEV_AUTH_LAN=true
    API="http://$LAN:$PORT"
    say "Phone talks to the backend at $API (dev auth is open to your LAN while this runs)"
    ;;
  *) DEVICE="$TARGET" ;;
esac

# --- backend --------------------------------------------------------------
BACKEND_PID=""
cleanup() {
  if [[ -n "$BACKEND_PID" ]]; then
    say "Stopping backend"
    kill "$BACKEND_PID" 2>/dev/null || true
    pkill -f everyai-backend-exp 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# -m: a backend that accepts but never answers (suspended, wedged) must not hang this.
healthy() { curl -sf -m 2 "$1/healthz" >/dev/null 2>&1; }

# A backend left from an earlier run that holds the port without answering
# (state T after a stray Ctrl-Z, or wedged) is replaced.
STALE="$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "$STALE" ]] && ! healthy "$API" && ! healthy "http://localhost:$PORT"; then
  for pid in $STALE; do
    if ps -o command= -p "$pid" | grep -q everyai-backend-exp; then
      say "Replacing an unresponsive backend on :$PORT (pid $pid)"
      parent="$(ps -o ppid= -p "$pid" | tr -d ' ')"
      # Its `zig build run` parent, when that is what started it.
      if [[ -n "$parent" ]] && ps -o command= -p "$parent" | grep -q 'build.*run'; then
        kill -CONT "$parent" 2>/dev/null || true
        kill "$parent" 2>/dev/null || true
      fi
      kill -CONT "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    else
      die "Port $PORT is held by something else (pid $pid: $(ps -o command= -p "$pid" | cut -c1-60)). Free it or set PORT=."
    fi
  done
  for _ in $(seq 1 20); do lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.25; done
  lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && kill -9 $STALE 2>/dev/null || true
fi

if healthy "$API"; then
  say "Backend already running at $API"
else
  if healthy "http://localhost:$PORT"; then
    die "A backend on :$PORT only listens on localhost. Stop it, then rerun (this one binds $HOST)."
  fi
  command -v zig >/dev/null || die "zig 0.17 is not on PATH."
  say "Starting backend-exp on $HOST:$PORT (log: .dev/backend.log)"
  # DEV_AUTH_LAN acknowledges that dev auth is open to the LAN (physical iPhone only).
  # stdin from /dev/null: a background job that touches the terminal is stopped (SIGTTIN).
  (cd "$BACKEND" && HOST="$HOST" DEV_AUTH_LAN="$DEV_AUTH_LAN" PORT="$PORT" exec zig build run) </dev/null >"$DEV/backend.log" 2>&1 &
  BACKEND_PID=$!
  for _ in $(seq 1 240); do
    healthy "$API" && break
    kill -0 "$BACKEND_PID" 2>/dev/null || { tail -20 "$DEV/backend.log"; die "Backend failed to start."; }
    sleep 0.5
  done
  healthy "$API" || die "Backend didn't come up; see .dev/backend.log."
  say "Backend ready"
fi

# --- app ------------------------------------------------------------------
DEFINES="$DEV/defines-$TARGET.json"
python3 - "$FRONTEND/config/dev.json" "$DEFINES" "$API" <<'PY'
import json, os, sys
src, dst, api = sys.argv[1:]
base = json.load(open(src)) if os.path.exists(src) else {"DEV_SKIP_AUTH": True, "SSE_ENABLED": True}
base["API_BASE_URL"] = api
json.dump(base, open(dst, "w"), indent=2)
PY

# An earlier run on this device left suspended (Ctrl-Z) keeps its build lock;
# resume-and-kill it. A live run in another terminal is left alone.
for pid in $(pgrep -f "flutter_tools.snapshot run -d $DEVICE " 2>/dev/null || true); do
  if [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == T* ]]; then
    say "Stopping a suspended flutter run on $DEVICE (pid $pid)"
    parent="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    # Its dev.sh, stopped along with it.
    ps -o command= -p "$parent" 2>/dev/null | grep -q 'scripts/dev.sh' && kill -KILL "$parent" 2>/dev/null || true
  fi
done

ARGS=(-d "$DEVICE" --dart-define-from-file="$DEFINES")
if [[ "$DEVICE" == macos ]]; then
  say "Checking Deno (run_script)"
  DENO="$("$FRONTEND/tool/fetch_deno.sh" | tail -1)" && ARGS+=(--dart-define=DENO_BIN="$DENO") || say "No Deno: run_script is off"
fi
[[ "$DEVICE" == chrome ]] && ARGS+=(--web-port=5173)

say "flutter run ${ARGS[*]} ${EXTRA[*]:-}"
cd "$FRONTEND"
flutter run "${ARGS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"
