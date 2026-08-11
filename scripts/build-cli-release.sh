#!/usr/bin/env bash
# Builds the universal (arm64 + x86_64) release binaries of the public
# `ttybuild` CLI and the `ttybuild-hook` reporter, stamped with the desktop
# release version so the standalone CLI and the copy embedded in the app
# always carry the same number. Outputs land in the desktop release
# directory for signing and packaging by the release workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ARTIFACT_ROOT="$REPOSITORY_ROOT/.artifacts"
OUTPUT_DIR="${TTYBUILD_DESKTOP_OUTPUT_DIR:-$ARTIFACT_ROOT/desktop-release}"
VERSION="${TTYBUILD_DESKTOP_VERSION:-}"
PACKAGE_PATH="$REPOSITORY_ROOT/desktop/TTYBuildDaemon"
VERSION_FILE="$PACKAGE_PATH/Sources/ttybuild/Version.swift"
MARKER="ttybuild-release-version-marker"

for command in swift lipo; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 1
  fi
done

if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "TTYBUILD_DESKTOP_VERSION must be a three-part numeric version." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

# Stamp the release version into the CLI (restored afterwards so local trees
# stay clean; CI workspaces are throwaway either way).
restore_version() {
  git -C "$REPOSITORY_ROOT" checkout -- "$VERSION_FILE" 2>/dev/null || true
}
if [[ -n "$VERSION" ]]; then
  grep -q "$MARKER" "$VERSION_FILE" || {
    echo "Version marker missing from $VERSION_FILE" >&2
    exit 1
  }
  trap restore_version EXIT
  sed -i '' "s/\"dev\" \/\/ $MARKER/\"$VERSION\" \/\/ $MARKER/" "$VERSION_FILE"
fi

swift build \
  --package-path "$PACKAGE_PATH" \
  --configuration release \
  --arch arm64 --arch x86_64 \
  --product ttybuild
swift build \
  --package-path "$PACKAGE_PATH" \
  --configuration release \
  --arch arm64 --arch x86_64 \
  --product ttybuild-hook

BIN_DIR="$PACKAGE_PATH/.build/apple/Products/Release"
for binary in ttybuild ttybuild-hook; do
  [[ -x "$BIN_DIR/$binary" ]] || {
    echo "Universal build output missing: $BIN_DIR/$binary" >&2
    exit 1
  }
  lipo -archs "$BIN_DIR/$binary" | grep -q "arm64" || {
    echo "$binary is not a universal binary" >&2
    exit 1
  }
  lipo -archs "$BIN_DIR/$binary" | grep -q "x86_64" || {
    echo "$binary is not a universal binary" >&2
    exit 1
  }
  cp "$BIN_DIR/$binary" "$OUTPUT_DIR/$binary"
done

if [[ -n "$VERSION" ]]; then
  reported="$("$OUTPUT_DIR/ttybuild" --version)"
  if [[ "$reported" != "$VERSION" ]]; then
    echo "ttybuild --version reported '$reported', expected '$VERSION'" >&2
    exit 1
  fi
fi

echo "Universal CLI binaries written to $OUTPUT_DIR (ttybuild, ttybuild-hook)"
