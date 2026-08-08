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

# Color only when talking to an interactive ANSI terminal.
if [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
  bold=$'\033[1m'
  green=$'\033[32m'
  red=$'\033[31m'
  reset=$'\033[0m'
else
  bold="" green="" red="" reset=""
fi

step() {
  printf '%s==>%s %s%s%s\n' "$green" "$reset" "$bold" "$*" "$reset"
}

fail() {
  printf '%spedals-install:%s %s\n' "$red" "$reset" "$*" >&2
  exit 1
}

app_version() {
  # Prints "1.2.3 (45)" for the app bundle at $1, or nothing if unreadable.
  local plist="$1/Contents/Info.plist" short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  [[ -n "$short" ]] || return 0
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
  if [[ -n "$build" && "$build" != "$short" ]]; then
    printf '%s (%s)' "$short" "$build"
  else
    printf '%s' "$short"
  fi
}

download() {
  # $1=url $2=destination; a progress bar when stderr is a terminal, silent
  # otherwise so piped and CI runs stay clean.
  if [[ -t 2 ]]; then
    curl -fL -# "$1" -o "$2"
  else
    curl -fsSL "$1" -o "$2"
  fi
}

[[ "$(uname -s)" == "Darwin" ]] || fail "this installer supports macOS only"

for cmd in curl shasum ditto; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command is unavailable: $cmd"
done

if [[ -n "${PEDALS_INSTALL_DIR:-}" ]]; then
  install_dir="$PEDALS_INSTALL_DIR"
  mkdir -p "$install_dir"
elif [[ -w /Applications ]]; then
  install_dir="/Applications"
else
  install_dir="$HOME/Applications"
  mkdir -p "$install_dir"
fi

installed_version=""
if [[ -d "$install_dir/$APP_NAME" ]]; then
  installed_version="$(app_version "$install_dir/$APP_NAME")"
  step "Pedals ${installed_version:-unknown version} is already installed in $install_dir"
  # stdin may be the script itself (curl | bash), so prompt via /dev/tty and
  # default to updating when no terminal is available to answer.
  answer=""
  printf 'Press return to update to the latest release, or q to quit: '
  read -r answer 2>/dev/null < /dev/tty || answer=""
  case "$answer" in
    q | Q | n | N | quit | exit)
      echo "Nothing changed."
      exit 0
      ;;
  esac
fi

workdir="$(mktemp -d -t pedals-install)"
staging="$install_dir/.$APP_NAME.installing"
cleanup() {
  rm -rf "$workdir" "$staging"
}
trap cleanup EXIT

step "Downloading the latest Pedals release"
download "$BASE_URL/download/macos.zip" "$workdir/$ZIP_NAME" \
  || fail "the release download failed"
curl -fsSL "$BASE_URL/download/macos.zip.sha256" -o "$workdir/$CHECKSUM_NAME" \
  || fail "the checksum download failed"

step "Verifying the archive checksum"
(cd "$workdir" && shasum -a 256 -c "$CHECKSUM_NAME" >/dev/null) \
  || fail "checksum verification failed; nothing was installed"

ditto -xk "$workdir/$ZIP_NAME" "$workdir/extract"
[[ -d "$workdir/extract/$APP_NAME" ]] || fail "the archive did not contain $APP_NAME"

new_version="$(app_version "$workdir/extract/$APP_NAME")"
if [[ -n "$new_version" && "$new_version" == "$installed_version" ]]; then
  step "Reinstalling Pedals $new_version (already the latest release)"
elif [[ -n "$new_version" ]]; then
  step "Installing Pedals $new_version to $install_dir"
else
  step "Installing Pedals to $install_dir"
fi

# Stage next to the destination, then swap, so a failed copy can never leave
# a half-written Pedals.app behind.
rm -rf "$staging"
ditto "$workdir/extract/$APP_NAME" "$staging"
rm -rf "${install_dir:?}/${APP_NAME:?}"
mv "$staging" "$install_dir/$APP_NAME"

step "Installed $install_dir/$APP_NAME"

if pgrep -x Pedals >/dev/null 2>&1; then
  # Never quit a running app without an explicit yes from a real terminal.
  answer=""
  printf 'Pedals is running. Press return to relaunch it now, or q to keep the current session: '
  read -r answer 2>/dev/null < /dev/tty || answer="q"
  case "$answer" in
    q | Q | n | N)
      echo "Quit and reopen Pedals whenever you're ready to use the new version."
      ;;
    *)
      osascript -e 'tell application "Pedals" to quit' >/dev/null 2>&1 || true
      tries=0
      while pgrep -x Pedals >/dev/null 2>&1 && (( tries < 20 )); do
        sleep 0.5
        tries=$(( tries + 1 ))
      done
      if pgrep -x Pedals >/dev/null 2>&1; then
        echo "Pedals didn't quit; close it and reopen to finish the update."
      else
        open "$install_dir/$APP_NAME"
        step "Relaunched Pedals"
      fi
      ;;
  esac
else
  open "$install_dir/$APP_NAME"
fi
