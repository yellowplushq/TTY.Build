#!/usr/bin/env bash
# Deploy the TTYBuild relay to Cloudflare Workers (ARCHITECTURE.md "Relay deploy").
#
# Requires: `wrangler login` for the Cloudflare account that owns eyhn.in.
# Runs the Worker/runtime tests before deploy and the external relay contract
# against the custom domain afterwards.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_DIR="$REPO_ROOT/relay"
URL="${RELAY_URL:-https://tty.build}"

cd "$RELAY_DIR"
npm ci
npm test

# Fail before touching remote D1 when APNs cannot be configured, then compile
# the exact Worker bundle. Migration 0005 intentionally removes the retired
# host-heartbeat columns, so an invalid bundle must never be discovered only
# after that breaking schema migration has started.
SECRET_NAMES="$(npx wrangler secret list --format json | node -e '
  const entries = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
  process.stdout.write(entries.map((entry) => entry.name).join("\n"));
')"
for required in APNS_PRIVATE_KEY_P8 APNS_KEY_ID APNS_TEAM_ID; do
  grep -qx "$required" <<<"$SECRET_NAMES" || {
    echo "missing required Worker secret: $required" >&2
    exit 1
  }
done

npm run deploy:dry-run
npm run db:migrate:remote

# Wrangler may report a 100% deployment before every edge serving the custom
# domain has loaded that version. Capture the immutable version UUID and wait
# for the public health response to prove that exact version is active. A plain
# 200 is insufficient because the previous Worker also serves /healthz.
DEPLOY_LOG="$(mktemp "${TMPDIR:-/tmp}/tty-build-relay-deploy.XXXXXX")"
cleanup_deploy_log() {
  rm -f "$DEPLOY_LOG"
}
trap cleanup_deploy_log EXIT
npm run deploy 2>&1 | tee "$DEPLOY_LOG"
CURRENT_VERSION_ID="$(node "$REPO_ROOT/scripts/parse-wrangler-version.mjs" < "$DEPLOY_LOG")"
cleanup_deploy_log
trap - EXIT

consecutive_matches=0
last_observed_version=""
for _ in $(seq 1 60); do
  observed_version="$(
    curl -fsS --connect-timeout 5 --max-time 10 \
      -o /dev/null \
      -w '%header{x-ttybuild-worker-version}' \
      "$URL/healthz" 2>/dev/null || true
  )"
  observed_version="${observed_version//$'\r'/}"
  observed_version="${observed_version//$'\n'/}"
  last_observed_version="$observed_version"
  if [[ "$observed_version" == "$CURRENT_VERSION_ID" ]]; then
    consecutive_matches=$((consecutive_matches + 1))
    if ((consecutive_matches >= 3)); then
      break
    fi
  else
    consecutive_matches=0
  fi
  sleep 2
done
if ((consecutive_matches < 3)); then
  echo "Worker version did not become ready at $URL" >&2
  echo "expected: $CURRENT_VERSION_ID" >&2
  echo "last observed: ${last_observed_version:-<missing header>}" >&2
  exit 1
fi

RELAY_HTTP_URL="$URL" npm run test:contract

mkdir -p "$REPO_ROOT/.artifacts"
printf '%s\n' "$URL" > "$REPO_ROOT/.artifacts/relay-url.txt"
printf '%s\n' "$CURRENT_VERSION_ID" > "$REPO_ROOT/.artifacts/relay-version.txt"
echo "worker URL:  $URL (recorded in .artifacts/relay-url.txt)"
echo "version ID: $CURRENT_VERSION_ID (recorded in .artifacts/relay-version.txt)"
echo "relay URL:   ${URL/https:\/\//wss://}"
