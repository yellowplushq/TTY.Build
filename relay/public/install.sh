#!/usr/bin/env bash
# Pedals desktop installer for macOS.
#
# Usage:
#   curl -fsSL https://pedals.air.build/i | bash
#   curl -fsSL https://pedals.air.build/12345678 | bash
#   curl -fsSL https://pedals.air.build/i | bash -s -- --pair 12345678
#
# Downloads the latest notarized Pedals-macOS.zip through the stable release
# redirect, verifies it against the SHA-256 checksum published with the same
# release, installs Pedals.app, and launches it. The 8-digit-path form serves
# this same script with that enrollment code baked into the PEDALS_PAIR
# default below; --pair and the PEDALS_PAIR environment variable do the same
# by hand. With a code, the launched app claims it so the computer appears in
# the iPhone app for confirmation without typing anything. The script never
# escalates privileges and never sends anything anywhere except the download
# requests. Keep it compatible with the bash 3.2 that ships with macOS.

set -euo pipefail

BASE_URL="${PEDALS_INSTALL_BASE_URL:-https://pedals.air.build}"
ZIP_NAME="Pedals-macOS.zip"
CHECKSUM_NAME="$ZIP_NAME.sha256"
APP_NAME="Pedals.app"
APP_BUNDLE_ID="air.build.pedals.menubar"

pair_code="${PEDALS_PAIR:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pair)
      [[ $# -ge 2 ]] || { echo "pedals-install: --pair needs a code" >&2; exit 1; }
      pair_code="$2"
      shift 2
      ;;
    --pair=*)
      pair_code="${1#--pair=}"
      shift
      ;;
    *)
      echo "pedals-install: unknown option: $1" >&2
      exit 1
      ;;
  esac
done
# Accept "1234 5678" / "1234-5678" the way the apps render codes.
pair_code="${pair_code//[- ]/}"
if [[ -n "$pair_code" && ! "$pair_code" =~ ^[0-9]{8}$ ]]; then
  echo "pedals-install: --pair expects the 8-digit code from the iPhone app" >&2
  exit 1
fi

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

app_is_running() {
  # The iPhone app in Simulator also has the process name "Pedals", so a
  # name-only pgrep reports a false positive whenever that simulator is open.
  # The desktop bundle identifier uniquely identifies the menu bar app and
  # remains stable while its bundle is replaced during an update.
  [[ "$(osascript -e "application id \"$APP_BUNDLE_ID\" is running" 2>/dev/null || true)" == "true" ]]
}

running_desktop_app_pids() {
  # Limit the name match to processes whose full command starts with the
  # executable inside the installed desktop bundle. Simulator apps share the
  # Pedals process name but have a different executable path.
  local executable pid command_line
  executable="$install_dir/$APP_NAME/Contents/MacOS/Pedals"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == "$executable" || "$command_line" == "$executable "* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -x Pedals 2>/dev/null || true)
}

terminate_desktop_app() {
  local pid
  while IFS= read -r pid; do
    kill "$pid" 2>/dev/null || true
  done < <(running_desktop_app_pids)
}

launch_app() {
  step "Opening Pedals"
  open "$install_dir/$APP_NAME" \
    || fail "macOS could not open $install_dir/$APP_NAME"
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
if [[ -n "$pair_code" ]]; then
  # Stamp the enrollment code as an extended attribute on the bundle. It is
  # outside the code-signature seal, survives the swap below and Finder
  # copies, and the app consumes it on launch — pairing completes even if
  # Pedals only starts (or restarts) later.
  xattr -w build.air.pedals.pairing-code "$pair_code" "$staging" \
    || echo "pedals-install: could not stamp the pairing code; connect with a code instead" >&2
fi
rm -rf "${install_dir:?}/${APP_NAME:?}"
mv "$staging" "$install_dir/$APP_NAME"

step "Installed $install_dir/$APP_NAME"

if app_is_running; then
  # Never quit a running app without an explicit yes from a real terminal.
  answer=""
  printf 'Pedals is running. Press return to relaunch it now, or q to keep the current session: '
  read -r answer 2>/dev/null < /dev/tty || answer="q"
  case "$answer" in
    q | Q | n | N)
      echo "Quit and reopen Pedals whenever you're ready to use the new version."
      ;;
    *)
      osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
      tries=0
      while app_is_running && (( tries < 20 )); do
        sleep 0.5
        tries=$(( tries + 1 ))
      done
      if app_is_running; then
        step "Pedals did not quit normally; stopping it before relaunch"
        terminate_desktop_app
        tries=0
        while app_is_running && (( tries < 20 )); do
          sleep 0.25
          tries=$(( tries + 1 ))
        done
      fi
      app_is_running \
        && fail "Pedals did not quit; close it and rerun the installer"
      launch_app
      ;;
  esac
else
  launch_app
fi

if [[ -n "$pair_code" ]]; then
  if app_is_running; then
    step "Open Pedals on your iPhone and confirm this computer"
  else
    step "Pairing completes the next time Pedals starts; then confirm on your iPhone"
  fi
fi
