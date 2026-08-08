#!/usr/bin/env bash
# Pedals desktop installer for macOS.
#
# Usage:
#   curl -fsSL https://pedals.air.build/install.sh | bash
#
# Downloads the latest notarized Pedals-macOS.zip through the stable release
# redirect, verifies it against the SHA-256 checksum published with the same
# release, installs Pedals.app, and launches it. The script never escalates
# privileges and never sends anything anywhere except the download requests.
# Keep it compatible with the bash 3.2 that ships with macOS.

set -euo pipefail

BASE_URL="${PEDALS_INSTALL_BASE_URL:-https://pedals.air.build}"
ZIP_NAME="Pedals-macOS.zip"
CHECKSUM_NAME="$ZIP_NAME.sha256"
APP_NAME="Pedals.app"

fail() {
  echo "pedals-install: $*" >&2
  exit 1
}

matrix_intro() {
  # A two-second nod to the Matrix. Skipped unless stderr is an interactive
  # ANSI terminal, so piping and CI logs stay clean.
  [[ -t 2 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]] || return 0
  local chars=(ｱ ｶ ｻ ﾀ ﾅ ﾊ ﾏ ﾔ ﾗ ﾜ ｦ ｰ 0 1 Z)
  local rows=8 cols=38 f i c line
  printf '\0337\033[?25l' >&2
  for ((f = 0; f < 12; f++)); do
    printf '\0338' >&2
    for ((i = 0; i < rows; i++)); do
      line=""
      for ((c = 0; c < cols; c++)); do
        line+="${chars[RANDOM % ${#chars[@]}]} "
      done
      printf '\033[32m%s\033[0m\n' "$line" >&2
    done
    sleep 0.06
  done
  printf '\0338\033[J\033[?25h' >&2
  printf '\033[32;1m  P E D A L S\033[0m  \033[32mfollow the white rabbit back to your terminal.\033[0m\n' >&2
}

[[ "$(uname -s)" == "Darwin" ]] || fail "this installer supports macOS only"

for command in curl shasum ditto; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done

matrix_intro

if [[ -n "${PEDALS_INSTALL_DIR:-}" ]]; then
  install_dir="$PEDALS_INSTALL_DIR"
  mkdir -p "$install_dir"
elif [[ -w /Applications ]]; then
  install_dir="/Applications"
else
  install_dir="$HOME/Applications"
  mkdir -p "$install_dir"
fi

if [[ -d "$install_dir/$APP_NAME" ]]; then
  installed_version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$install_dir/$APP_NAME/Contents/Info.plist" 2>/dev/null || true)"
  echo "Pedals ${installed_version:-unknown version} is already installed in $install_dir."
  # stdin may be the script itself (curl | bash), so prompt via /dev/tty and
  # default to updating when no terminal is available to answer.
  answer=""
  printf 'Press return to update to the latest release, or q to quit: '
  read -r answer 2>/dev/null < /dev/tty || answer=""
  case "$answer" in
    q|Q|n|N|quit|exit)
      echo "Nothing changed."
      exit 0
      ;;
  esac
fi

workdir="$(mktemp -d -t pedals-install)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

echo "Downloading the latest Pedals release..."
curl -fsSL "$BASE_URL/download/macos.zip" -o "$workdir/$ZIP_NAME" \
  || fail "the release download failed"
curl -fsSL "$BASE_URL/download/macos.zip.sha256" -o "$workdir/$CHECKSUM_NAME" \
  || fail "the checksum download failed"

echo "Verifying the archive checksum..."
(cd "$workdir" && shasum -a 256 -c "$CHECKSUM_NAME" >/dev/null) \
  || fail "checksum verification failed; nothing was installed"

ditto -xk "$workdir/$ZIP_NAME" "$workdir/extract"
[[ -d "$workdir/extract/$APP_NAME" ]] || fail "the archive did not contain $APP_NAME"

rm -rf "$install_dir/$APP_NAME"
ditto "$workdir/extract/$APP_NAME" "$install_dir/$APP_NAME"

echo "Installed $install_dir/$APP_NAME"
if pgrep -x Pedals >/dev/null 2>&1; then
  echo "Pedals is currently running; quit and reopen it to use the new version."
else
  open "$install_dir/$APP_NAME"
fi
