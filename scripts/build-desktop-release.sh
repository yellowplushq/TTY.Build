#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ARTIFACT_ROOT="$REPOSITORY_ROOT/.artifacts"
OUTPUT_DIR="${TTYBUILD_DESKTOP_OUTPUT_DIR:-$ARTIFACT_ROOT/desktop-release}"
VERSION="${TTYBUILD_DESKTOP_VERSION:-1.0.0}"
BUILD_NUMBER="${TTYBUILD_DESKTOP_BUILD_NUMBER:-1}"
ARCHITECTURES=(arm64 x86_64)

for command in xcodebuild xcodegen lipo ditto; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 1
  fi
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "TTYBUILD_DESKTOP_VERSION must be a three-part numeric version." >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "TTYBUILD_DESKTOP_BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi

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

BUILD_DIR="$OUTPUT_DIR/build"
APP_PATH="$OUTPUT_DIR/TTYBuild.app"

rm -rf "$BUILD_DIR" "$APP_PATH"
mkdir -p "$BUILD_DIR"

pushd "$REPOSITORY_ROOT/desktop/TTYBuildMenubar" >/dev/null
xcodegen generate
xcodebuild \
  -project TTYBuildMenubar.xcodeproj \
  -scheme TTYBuildMenubar \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_DIR/derived-data" \
  ARCHS="${ARCHITECTURES[*]}" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build
popd >/dev/null

BUILT_APP="$BUILD_DIR/derived-data/Build/Products/Release/TTYBuild.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Xcode did not produce $BUILT_APP" >&2
  exit 1
fi

ditto "$BUILT_APP" "$APP_PATH"

lipo "$APP_PATH/Contents/MacOS/TTYBuild" -verify_arch "${ARCHITECTURES[@]}"

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [[ "$actual_version" != "$VERSION" || "$actual_build" != "$BUILD_NUMBER" ]]; then
  echo "Built version $actual_version ($actual_build) does not match $VERSION ($BUILD_NUMBER)." >&2
  exit 1
fi
if [[ "$actual_identifier" != "build.tty.menubar" ]]; then
  echo "Unexpected desktop bundle identifier: $actual_identifier" >&2
  exit 1
fi

echo "Built universal desktop app: $APP_PATH"
