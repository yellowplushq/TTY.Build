#!/bin/bash
# Builds a pinned, self-contained, universal (arm64 + x86_64) tmux binary and
# places it at desktop/PedalsMenubar/Resources/tmux for embedding into the
# menu bar app. ncurses and libevent are built as static libraries only, so
# the final tmux binary dynamically links just the macOS system libraries.
#
# Pinned tarball SHA256 hashes were obtained 2026-08-09 by downloading each
# release tarball from the URLs below and running `shasum -a 256` on them.
#
# Environment:
#   PEDALS_TMUX_BUILD_DIR  work directory (default: .artifacts/tmux-build)
#   FORCE=1                rebuild even if the output is already current
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${PEDALS_TMUX_BUILD_DIR:-$REPO_ROOT/.artifacts/tmux-build}"
CACHE_DIR="$WORK_DIR/cache"
OUTPUT="$REPO_ROOT/desktop/PedalsMenubar/Resources/tmux"
MARKER="$WORK_DIR/pinned-versions"

TMUX_VERSION="3.5a"
TMUX_URL="https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz"
TMUX_SHA256="16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951"

LIBEVENT_VERSION="2.1.12-stable"
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz"
LIBEVENT_SHA256="92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb"

NCURSES_VERSION="6.5"
NCURSES_URL="https://invisible-mirror.net/archives/ncurses/ncurses-6.5.tar.gz"
NCURSES_SHA256="136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"

MACOSX_MIN="14.0"
ARCHES="arm64 x86_64"
JOBS="$(sysctl -n hw.ncpu)"
EXPECTED_MARKER="tmux $TMUX_VERSION / libevent $LIBEVENT_VERSION / ncurses $NCURSES_VERSION"

if [[ "${FORCE:-0}" != "1" && -x "$OUTPUT" && -f "$MARKER" ]] \
  && [[ "$(cat "$MARKER")" == "$EXPECTED_MARKER" ]]; then
  echo "tmux $TMUX_VERSION is already built at $OUTPUT (set FORCE=1 to rebuild)."
  exit 0
fi

mkdir -p "$CACHE_DIR" "$(dirname "$OUTPUT")"

download() {
  local url="$1" sha256="$2" dest="$3"
  if [[ -f "$dest" ]] \
    && [[ "$(shasum -a 256 "$dest" | awk '{print $1}')" == "$sha256" ]]; then
    echo "Using cached $(basename "$dest")"
    return
  fi
  echo "Downloading $url"
  curl -fSL --retry 3 -o "$dest" "$url"
  local actual
  actual="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [[ "$actual" != "$sha256" ]]; then
    echo "SHA256 mismatch for $dest: expected $sha256, got $actual" >&2
    exit 1
  fi
}

download "$TMUX_URL" "$TMUX_SHA256" "$CACHE_DIR/tmux-$TMUX_VERSION.tar.gz"
download "$LIBEVENT_URL" "$LIBEVENT_SHA256" "$CACHE_DIR/libevent-$LIBEVENT_VERSION.tar.gz"
download "$NCURSES_URL" "$NCURSES_SHA256" "$CACHE_DIR/ncurses-$NCURSES_VERSION.tar.gz"

build_arch() {
  local arch="$1"
  local prefix="$WORK_DIR/prefix/$arch"
  local build="$WORK_DIR/build/$arch"
  local arch_flags="-arch $arch -mmacosx-version-min=$MACOSX_MIN"
  rm -rf "$build" "$prefix"
  mkdir -p "$build" "$prefix"

  # Cross builds need --host so configure skips run-tests. The host triplet
  # must be aarch64-apple-darwin (not arm64-apple-darwin) because the config.sub
  # shipped with ncurses does not recognize the arm64 spelling.
  local host_arg=""
  if [[ "$arch" != "$(uname -m)" ]]; then
    case "$arch" in
      arm64) host_arg="--host=aarch64-apple-darwin" ;;
      x86_64) host_arg="--host=x86_64-apple-darwin" ;;
    esac
  fi

  # ncurses: static, wide-char only, no progs/tests/manpages (tic is not
  # needed; the daemon uses screen-256color, whose terminfo entry macOS ships
  # in /usr/share/terminfo). --enable-overwrite puts headers directly in
  # include/ so tmux's non-pkg-config fallback checks find them.
  tar -xzf "$CACHE_DIR/ncurses-$NCURSES_VERSION.tar.gz" -C "$build"
  (
    cd "$build/ncurses-$NCURSES_VERSION"
    ./configure \
      $host_arg \
      --prefix="$prefix" \
      --disable-shared \
      --enable-static \
      --enable-widec \
      --enable-overwrite \
      --with-default-terminfo-dir=/usr/share/terminfo \
      --without-ada \
      --without-cxx \
      --without-cxx-binding \
      --without-progs \
      --without-tests \
      --without-manpages \
      --without-debug \
      CFLAGS="$arch_flags -Os" \
      LDFLAGS="$arch_flags"
    make -j"$JOBS"
    make install.libs install.includes
  )
  # tmux's fallback detection may add -lncurses and look for ncurses.h; make
  # both resolve to the wide-char build.
  ln -sf libncursesw.a "$prefix/lib/libncurses.a"
  if [[ ! -f "$prefix/include/ncurses.h" ]]; then
    ln -sf curses.h "$prefix/include/ncurses.h"
  fi

  # libevent: static only, without openssl so no extra dependency sneaks in.
  tar -xzf "$CACHE_DIR/libevent-$LIBEVENT_VERSION.tar.gz" -C "$build"
  (
    cd "$build/libevent-$LIBEVENT_VERSION"
    ./configure \
      $host_arg \
      --prefix="$prefix" \
      --disable-shared \
      --enable-static \
      --disable-openssl \
      --disable-libevent-regress \
      --disable-samples \
      CFLAGS="$arch_flags -Os" \
      LDFLAGS="$arch_flags"
    make -j"$JOBS"
    make install
  )

  # tmux. --enable-static must NOT be passed: tmux's configure rejects it on
  # Darwin. Static linkage of libevent/ncurses is guaranteed because the
  # per-arch prefix contains only .a files. PKG_CONFIG_LIBDIR pins pkg-config
  # (when present) to the per-arch prefix so no system package is picked up.
  tar -xzf "$CACHE_DIR/tmux-$TMUX_VERSION.tar.gz" -C "$build"
  (
    cd "$build/tmux-$TMUX_VERSION"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    # tmux does not vendor utf8proc and configure refuses a default on macOS;
    # disable it rather than add a dynamic dependency.
    ./configure \
      $host_arg \
      --prefix="$prefix" \
      --disable-utf8proc \
      CFLAGS="$arch_flags -Os" \
      CPPFLAGS="-I$prefix/include" \
      LDFLAGS="$arch_flags -L$prefix/lib"
    make -j"$JOBS"
  )
}

for arch in $ARCHES; do
  echo "=== Building for $arch ==="
  build_arch "$arch"
done

lipo -create \
  "$WORK_DIR/build/arm64/tmux-$TMUX_VERSION/tmux" \
  "$WORK_DIR/build/x86_64/tmux-$TMUX_VERSION/tmux" \
  -output "$OUTPUT"
chmod +x "$OUTPUT"

# The binary must link only macOS system libraries dynamically.
bad_deps="$(otool -L "$OUTPUT" \
  | awk '/^[[:space:]]+\// {print $1}' \
  | grep -v -E '^/usr/lib/|^/System/' || true)"
if [[ -n "$bad_deps" ]]; then
  echo "error: $OUTPUT links non-system libraries:" >&2
  echo "$bad_deps" >&2
  exit 1
fi

version_output="$("$OUTPUT" -V)"
if [[ "$version_output" != "tmux $TMUX_VERSION" ]]; then
  echo "error: smoke test failed: expected 'tmux $TMUX_VERSION', got '$version_output'" >&2
  exit 1
fi

echo "$EXPECTED_MARKER" > "$MARKER"
echo "Built universal tmux $TMUX_VERSION at $OUTPUT"
lipo -info "$OUTPUT"
