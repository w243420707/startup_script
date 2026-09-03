#!/bin/sh

set -eu

REPOSITORY_ARCHIVE="https://github.com/w243420707/startup_script/archive/refs/heads/main.tar.gz"
INSTALL_DIR="/opt/startup-script"
TEMP_DIR="${TMPDIR:-/tmp}/startup-script-install.$$"
ARCHIVE_PATH="$TEMP_DIR/source.tar.gz"
STAGE_DIR="$TEMP_DIR/stage"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT INT TERM

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' '[ERROR] Please run this command as root.' >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '%s\n' '[ERROR] curl is required to download the startup script.' >&2
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  printf '%s\n' '[ERROR] tar is required to install the startup script.' >&2
  exit 1
fi

NZ_CLIENT_SECRET="${1:-${NZ_CLIENT_SECRET:-}}"
NZ_UUID="${2:-${NZ_UUID:-}}"
NZ_SERVER="${NZ_SERVER:-tz.114431.xyz:443}"
NZ_TLS="${NZ_TLS:-true}"

if [ -z "$NZ_CLIENT_SECRET" ] || [ -z "$NZ_UUID" ]; then
  printf '%s\n' '[ERROR] NZ_CLIENT_SECRET and NZ_UUID are required.' >&2
  printf '%s\n' "Usage: curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/main/install.sh | sh -s -- 'CLIENT_SECRET' 'UUID'" >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

if ! curl -fL --connect-timeout 15 --max-time 120 "$REPOSITORY_ARCHIVE" -o "$ARCHIVE_PATH"; then
  printf '%s\n' '[ERROR] Could not download the startup script repository.' >&2
  exit 1
fi

if ! tar -xzf "$ARCHIVE_PATH" -C "$STAGE_DIR" --strip-components=1; then
  printf '%s\n' '[ERROR] Could not extract the startup script repository.' >&2
  exit 1
fi

if [ ! -f "$STAGE_DIR/startup.sh" ] ||
   [ ! -f "$STAGE_DIR/VERSION" ] ||
   [ ! -d "$STAGE_DIR/lib" ] ||
   [ ! -d "$STAGE_DIR/steps" ]; then
  printf '%s\n' '[ERROR] The downloaded repository is incomplete.' >&2
  exit 1
fi

if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
  printf '%s\n' '[ERROR] The installation path is not a directory.' >&2
  exit 1
fi

rm -rf "$INSTALL_DIR"
mv "$STAGE_DIR" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/startup.sh"

export NZ_SERVER NZ_TLS NZ_CLIENT_SECRET NZ_UUID
"$INSTALL_DIR/startup.sh" install --yes
