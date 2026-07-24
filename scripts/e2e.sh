#!/usr/bin/env bash
# Pedals v2 end-to-end test.
#
# Local Worker + D1 -> desktop pairing code -> durable client binding ->
# server-authoritative TTY aggregation -> iOS code entry -> encrypted
# relay handshake -> simulator screenshot.
#
# Requires: Xcode, xcodegen, Node.js >= 22, Swift 6, and an available iPhone
# simulator. The script creates only temporary state below /tmp and .artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$ROOT/.artifacts"
RELAY_PORT="${RELAY_PORT:-8787}"
SERVICE_URL="http://127.0.0.1:$RELAY_PORT"
SIM_DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"
SIM_UDID="${SIM_UDID:-}"
BUNDLE_ID="air.build.pedals"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mkdir -p "$ARTIFACTS"
PEDALS_E2E_HOME="$(mktemp -d /tmp/pedals-e2e.XXXXXX)"
PEDALS_E2E_D1="$(mktemp -d /tmp/pedals-e2e-d1.XXXXXX)"
STATUS_CREDENTIAL="$PEDALS_E2E_HOME/status-client.json"
export PEDALS_HOME="$PEDALS_E2E_HOME"

log() { printf '\033[1;36m[e2e]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[e2e] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

RELAY_PID=""
DAEMON_PID=""
cleanup() {
  if [[ -n "$DAEMON_PID" ]]; then
    kill "$DAEMON_PID" 2>/dev/null || true
  fi
  if [[ -n "$RELAY_PID" ]]; then
    kill "$RELAY_PID" 2>/dev/null || true
  fi
  # Wait for both processes to release their Unix socket and D1 files before
  # removing the isolated directories. Without the wait, repeat runs race a
  # still-shutting-down wrangler process and print "Directory not empty".
  if [[ -n "$DAEMON_PID" ]]; then
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [[ -n "$RELAY_PID" ]]; then
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  rm -rf "$PEDALS_E2E_HOME" "$PEDALS_E2E_D1"
}
trap cleanup EXIT

# ---- 1. local Cloudflare service ----------------------------------------

log "installing and testing Worker dependencies"
(cd "$ROOT/relay" && npm ci --no-audit --no-fund --silent && npm test)

log "applying the v2 schema to an isolated local D1"
(
  cd "$ROOT/relay"
  WRANGLER_LOG_PATH="$ARTIFACTS/wrangler-e2e.log" \
    CI=1 npx wrangler d1 migrations apply pedals --local --persist-to "$PEDALS_E2E_D1"
)

log "starting the Cloudflare Worker on :$RELAY_PORT"
(
  cd "$ROOT/relay"
  WRANGLER_LOG_PATH="$ARTIFACTS/wrangler-e2e.log" \
    npx wrangler dev --local --ip 127.0.0.1 --port "$RELAY_PORT" \
      --persist-to "$PEDALS_E2E_D1"
) >"$ARTIFACTS/relay-e2e.log" 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 80); do
  curl -fsS "$SERVICE_URL/healthz" >/dev/null 2>&1 && break
  kill -0 "$RELAY_PID" 2>/dev/null || fail "Worker exited during startup"
  sleep 0.25
done
curl -fsS "$SERVICE_URL/healthz" >/dev/null || fail "Worker /healthz not responding"

# ---- 2. desktop registration and binding graph -------------------------

log "building and starting the desktop daemon"
swift build --package-path "$ROOT/desktop/PedalsDaemon" >/dev/null
PEDALS_BIN="$(swift build --package-path "$ROOT/desktop/PedalsDaemon" --show-bin-path)/pedals"
[[ -x "$PEDALS_BIN" ]] || fail "daemon binary not found at $PEDALS_BIN"

"$PEDALS_BIN" serve --service "$SERVICE_URL" \
  >"$ARTIFACTS/daemon-e2e.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 80); do
  [[ -S "$PEDALS_E2E_HOME/pedals.sock" && -f "$PEDALS_E2E_HOME/identity.json" ]] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "daemon exited during startup"
  sleep 0.25
done
[[ -S "$PEDALS_E2E_HOME/pedals.sock" ]] || fail "daemon control socket never appeared"

PAIR_CODE="$("$PEDALS_BIN" pair | sed -n 's/^Pairing code: //p' | tr -d ' ')"
[[ "$PAIR_CODE" =~ ^[0-9]{8}$ ]] || fail "daemon did not emit an 8-digit pairing code"
node "$ROOT/scripts/e2e-status-client.mjs" bind \
  "$SERVICE_URL" "$PAIR_CODE" "$STATUS_CREDENTIAL"

log "checking server-authoritative TTY aggregation"
node "$ROOT/scripts/e2e-status-client.mjs" wait "$STATUS_CREDENTIAL" 0
SESSION_ID="$("$PEDALS_BIN" new | sed -n 's/^created session //p')"
[[ "$SESSION_ID" =~ ^[0-9]+$ ]] || fail "could not parse created session id"
node "$ROOT/scripts/e2e-status-client.mjs" wait "$STATUS_CREDENTIAL" 1
"$PEDALS_BIN" kill "$SESSION_ID" >/dev/null
node "$ROOT/scripts/e2e-status-client.mjs" wait "$STATUS_CREDENTIAL" 0

# ---- 3. iOS pairing and encrypted relay handshake ----------------------

log "generating and building the iOS, Widget, Live Activity, and Watch targets"
(cd "$ROOT/ios" && xcodegen generate --quiet)

if [[ -z "$SIM_UDID" ]]; then
  SIM_UDID="$(xcrun simctl list devices available --json | node -e '
    const data = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
    const all = Object.values(data.devices).flat();
    const match = all.find((device) => device.name === process.argv[1]);
    if (!match) process.exit(1);
    process.stdout.write(match.udid);
  ' "$SIM_DEVICE")" || fail "no available simulator named '$SIM_DEVICE'"
else
  xcrun simctl list devices available --json | node -e '
    const data = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
    const all = Object.values(data.devices).flat();
    if (!all.some((device) => device.udid === process.argv[1])) process.exit(1);
  ' "$SIM_UDID" || fail "simulator '$SIM_UDID' is not available"
fi
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null

xcodebuild \
  -project "$ROOT/ios/Pedals.xcodeproj" \
  -scheme Pedals \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$ARTIFACTS/dd-ios" \
  -quiet build || fail "iOS build failed"

APP_PATH="$ARTIFACTS/dd-ios/Build/Products/Debug-iphonesimulator/Pedals.app"
[[ -d "$APP_PATH" ]] || fail "built app not found at $APP_PATH"
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM_UDID" "$APP_PATH"

IOS_PAIR_CODE="$("$PEDALS_BIN" pair | sed -n 's/^Pairing code: //p' | tr -d ' ')"
[[ "$IOS_PAIR_CODE" =~ ^[0-9]{8}$ ]] || fail "no fresh iOS pairing code"
SIMCTL_CHILD_PEDALS_SERVICE_URL="$SERVICE_URL" \
SIMCTL_CHILD_PEDALS_RESET_PAIRING=1 \
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null

# Drive the same visible controls a user sees. Baguette uses accessibility
# labels to locate each control, so this stays independent of device size.
tap_accessibility_label() {
  local label="$1"
  local ui_json="$PEDALS_E2E_HOME/ui.json"
  local point=""
  for _ in $(seq 1 40); do
    baguette describe-ui --udid "$SIM_UDID" --output "$ui_json" >/dev/null 2>&1
    if point="$(node - "$ui_json" "$label" <<'NODE'
const fs = require("node:fs");
const root = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const wanted = process.argv[3];
function visit(value) {
  if (!value || typeof value !== "object") return null;
  if (value.label === wanted || value.identifier === wanted) {
    const frame = value.frame || value.rect || value.bounds;
    if (frame) {
      const x = frame.x ?? frame.origin?.x;
      const y = frame.y ?? frame.origin?.y;
      const width = frame.width ?? frame.size?.width;
      const height = frame.height ?? frame.size?.height;
      if ([x, y, width, height].every(Number.isFinite)) {
        return `${x + width / 2} ${y + height / 2}`;
      }
    }
  }
  for (const child of Object.values(value)) {
    if (Array.isArray(child)) {
      for (const item of child) {
        const found = visit(item);
        if (found) return found;
      }
    } else {
      const found = visit(child);
      if (found) return found;
    }
  }
  return null;
}
const point = visit(root);
if (!point) process.exit(1);
process.stdout.write(`${point} ${root.frame.width} ${root.frame.height}`);
NODE
)"; then
      break
    fi
    point=""
    sleep 0.25
  done
  [[ -n "$point" ]] || fail "could not find visible control '$label'"
  read -r tap_x tap_y tap_width tap_height <<<"$point"
  baguette tap --udid "$SIM_UDID" --x "$tap_x" --y "$tap_y" \
    --width "$tap_width" --height "$tap_height" --duration 0.15 >/dev/null
}

# The onboarding content has a deliberate entrance transition. Accessibility
# publishes the button before it is fully hit-testable, so wait for that
# transition before driving the first visible control.
sleep 3
tap_accessibility_label "pedals.onboarding.pair"

# Simulator HID delivery can occasionally acknowledge a tap without UIKit
# receiving it. Prove that navigation completed and retry the source control
# instead of treating one dropped synthetic tap as an application failure.
PAIRING_UI_JSON="$PEDALS_E2E_HOME/pairing-ui.json"
for _ in $(seq 1 3); do
  sleep 1
  baguette describe-ui --udid "$SIM_UDID" --output "$PAIRING_UI_JSON" >/dev/null 2>&1
  if grep -q '"identifier":"pedals.pairing.code"' "$PAIRING_UI_JSON"; then
    break
  fi
  tap_accessibility_label "pedals.onboarding.pair"
done
grep -q '"identifier":"pedals.pairing.code"' "$PAIRING_UI_JSON" \
  || fail "pairing screen did not appear after tapping Connect"
tap_accessibility_label "pedals.pairing.code"
baguette type --udid "$SIM_UDID" --text "$IOS_PAIR_CODE" >/dev/null
tap_accessibility_label "pedals.pairing.submit"

log "waiting for the iOS client to prove the E2EE relay handshake"
CLIENT_STATE="none"
for attempt in $(seq 1 3); do
  for _ in $(seq 1 8); do
    CLIENT_STATE="$("$PEDALS_BIN" status | sed -n 's/^client: //p')"
    [[ "$CLIENT_STATE" == "connected" ]] && break 2
    sleep 0.5
  done

  # Simulator HID can also acknowledge the submit tap without UIKit receiving
  # it. Retry only while the pairing button is still on screen; after a real
  # submit it is disabled and repeated taps are harmless, and after success it
  # disappears entirely.
  SUBMIT_UI_JSON="$PEDALS_E2E_HOME/submit-ui.json"
  baguette describe-ui --udid "$SIM_UDID" --output "$SUBMIT_UI_JSON" >/dev/null 2>&1
  if grep -q '"identifier":"pedals.pairing.submit"' "$SUBMIT_UI_JSON"; then
    tap_accessibility_label "pedals.pairing.submit"
  else
    break
  fi
done
for _ in $(seq 1 56); do
  [[ "$CLIENT_STATE" == "connected" ]] && break
  CLIENT_STATE="$("$PEDALS_BIN" status | sed -n 's/^client: //p')"
  [[ "$CLIENT_STATE" == "connected" ]] && break
  sleep 0.5
done
[[ "$CLIENT_STATE" == "connected" ]] || fail "iOS client never completed the relay handshake"

"$PEDALS_BIN" new >/dev/null
sleep 3
SCREENSHOT="$ARTIFACTS/ios-terminal.png"
xcrun simctl io "$SIM_UDID" screenshot "$SCREENSHOT" >/dev/null
[[ -s "$SCREENSHOT" ]] || fail "simulator screenshot is empty"

log "v2 E2E passed; screenshot: $SCREENSHOT"
