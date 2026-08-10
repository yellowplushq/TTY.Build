#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ARTIFACT_ROOT="$REPOSITORY_ROOT/.artifacts"
OUTPUT_DIR="${TTYBUILD_DESKTOP_OUTPUT_DIR:-$ARTIFACT_ROOT/desktop-release}"
APP_PATH="$OUTPUT_DIR/TTYBuild.app"
DMG_PATH="$OUTPUT_DIR/TTYBuild-macOS.dmg"
STAGING_DIR="$OUTPUT_DIR/dmg-root"

for command in hdiutil ditto; do
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

rm -rf "$STAGING_DIR"
rm -f "$DMG_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/TTYBuild.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname TTYBuild \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG_PATH"

echo "Packaged desktop disk image: $DMG_PATH"
