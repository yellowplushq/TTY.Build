#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ARTIFACT_ROOT="$REPOSITORY_ROOT/.artifacts"
OUTPUT_DIR="${PEDALS_DESKTOP_OUTPUT_DIR:-$ARTIFACT_ROOT/desktop-release}"
APP_PATH="$OUTPUT_DIR/Pedals.app"
ZIP_PATH="$OUTPUT_DIR/Pedals-macOS.zip"

for command in ditto; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 1
  fi
done

mkdir -p "$ARTIFACT_ROOT" "$OUTPUT_DIR"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd -P)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
case "$OUTPUT_DIR/" in
  "$ARTIFACT_ROOT/"*) ;;
  *)
    echo "Desktop release output must stay below $ARTIFACT_ROOT" >&2
    exit 1
    ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build the desktop app before packaging: $APP_PATH" >&2
  exit 1
fi

rm -f "$ZIP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Packaged desktop zip archive: $ZIP_PATH"
