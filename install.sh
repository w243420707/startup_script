#!/bin/sh

set -eu

REPOSITORY_ARCHIVE="https://github.com/w243420707/startup_script/archive/refs/heads/feat/one-click-installer.tar.gz"
REPOSITORY_VERSION="https://raw.githubusercontent.com/w243420707/startup_script/feat/one-click-installer/VERSION"
INSTALL_DIR="/opt/startup-script"
TEMP_DIR=""
ARCHIVE_PATH=""
STAGE_DIR=""
BACKUP_DIR=""
STATE_DIR="${STARTUP_SCRIPT_STATE_DIR:-/var/lib/startup-script}"
AUTO_UPDATE_MODE=0

cleanup() {
  [ -z "$TEMP_DIR" ] || rm -rf "$TEMP_DIR"
}

trap cleanup EXIT INT TERM

install_bootstrap_dependencies() {
  attempt=1
  export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a

  while [ "$attempt" -le 3 ]; do
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache ca-certificates curl tar gzip coreutils
    elif command -v apt-get >/dev/null 2>&1; then
      dpkg --force-confold --configure -a >/dev/null 2>&1 || true
      apt-get -o DPkg::Lock::Timeout=300 update &&
        apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold install -y ca-certificates curl tar gzip coreutils
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y ca-certificates curl tar gzip coreutils
    elif command -v yum >/dev/null 2>&1; then
      yum install -y ca-certificates curl tar gzip coreutils
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm ca-certificates curl tar gzip coreutils
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive install -y ca-certificates curl tar gzip coreutils
    else
      return 1
    fi

    if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && command -v mktemp >/dev/null 2>&1; then
      return 0
    fi
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done

  return 1
}

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' '[ERROR] Please run this command as root.' >&2
  exit 1
fi

if [ "$#" -eq 0 ] && [ -r "$STATE_DIR/startup.env" ]; then
  AUTO_UPDATE_MODE=1
  set -a
  if ! . "$STATE_DIR/startup.env"; then
    set +a
    printf '%s\n' '[ERROR] Could not read the saved startup configuration.' >&2
    exit 1
  fi
  set +a
fi

if ! command -v curl >/dev/null 2>&1 ||
   ! command -v tar >/dev/null 2>&1 ||
   ! command -v mktemp >/dev/null 2>&1; then
  if ! install_bootstrap_dependencies; then
    printf '%s\n' '[ERROR] Could not install the bootstrap dependencies.' >&2
    exit 1
  fi
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/startup-script-install.XXXXXX")"
ARCHIVE_PATH="$TEMP_DIR/source.tar.gz"
STAGE_DIR="$TEMP_DIR/stage"

NZ_SERVER="${1:-${NZ_SERVER:-}}"
NZ_CLIENT_SECRET="${2:-${NZ_CLIENT_SECRET:-}}"
NZ_UUID="${3:-${NZ_UUID:-}}"
NZ_TLS="${NZ_TLS:-true}"
CFKEY="${4:-${CFKEY:-}}"
CFUSER="${5:-${CFUSER:-}}"
CFRECORD_NAME="${6:-${CFRECORD_NAME:-}}"
ApiHost="${7:-${ApiHost:-}}"
ApiKey="${8:-${ApiKey:-}}"
NodeID_anytls="${9:-${NodeID_anytls:-}}"
NodeID_hysteria2="${10:-${NodeID_hysteria2:-}}"
TG_BOT_TOKEN="${11:-${TG_BOT_TOKEN:-}}"
TG_USER_ID="${12:-${TG_USER_ID:-${TG_CHAT_ID:-${TG_USERID:-}}}}"

version_is_newer() {
  awk -F. -v remote="$1" -v local="$2" '
    BEGIN {
      if (remote !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
      if (local !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 0
      split(remote, r)
      split(local, l)
      for (i = 1; i <= 3; i++) {
        if ((r[i] + 0) > (l[i] + 0)) exit 0
        if ((r[i] + 0) < (l[i] + 0)) exit 1
      }
      exit 1
    }
  '
}

run_local_install() {
  if [ -x "$INSTALL_DIR/startup.sh" ]; then
    exec "$INSTALL_DIR/startup.sh" install --yes
  fi

  printf '%s\n' '[ERROR] The current startup script is missing.' >&2
  exit 1
}

if [ "$AUTO_UPDATE_MODE" -eq 1 ]; then
  CURRENT_VERSION="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION" 2>/dev/null || printf '0.0.0')"
  REMOTE_VERSION="$(curl -fsSL --connect-timeout 15 --max-time 45 "$REPOSITORY_VERSION" 2>/dev/null | tr -d '[:space:]')" || {
    printf '%s\n' '[WARN] Could not check GitHub for a newer startup script. Using the local version.' >&2
    run_local_install
  }

  if ! version_is_newer "$REMOTE_VERSION" "$CURRENT_VERSION"; then
    printf '[INFO] Startup script %s is current; running local self-healing.\n' "$CURRENT_VERSION" >&2
    run_local_install
  fi

  printf '[INFO] A newer startup script was found: %s -> %s.\n' "$CURRENT_VERSION" "$REMOTE_VERSION" >&2
fi

if [ -z "$NZ_SERVER" ] || [ -z "$NZ_CLIENT_SECRET" ] || [ -z "$NZ_UUID" ] ||
   [ -z "$CFKEY" ] || [ -z "$CFUSER" ] || [ -z "$CFRECORD_NAME" ] ||
   [ -z "$ApiHost" ] || [ -z "$ApiKey" ] ||
   [ -z "$NodeID_anytls" ] || [ -z "$NodeID_hysteria2" ] ||
   [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_USER_ID" ]; then
  printf '[ERROR] All 12 variables are required:\n' >&2
  printf '  NZ_SERVER NZ_CLIENT_SECRET NZ_UUID\n' >&2
  printf '  CFKEY CFUSER CFRECORD_NAME\n' >&2
  printf '  ApiHost ApiKey NodeID_anytls NodeID_hysteria2\n' >&2
  printf '  TG_BOT_TOKEN TG_USER_ID\n' >&2
  exit 1
fi

case "$NodeID_anytls" in
  ''|*[!0-9]*|0*)
    printf '[ERROR] NodeID_anytls must be a positive integer without leading zeroes: %s\n' "$NodeID_anytls" >&2
    exit 1
    ;;
esac

case "$NodeID_hysteria2" in
  ''|*[!0-9]*|0*)
    printf '[ERROR] NodeID_hysteria2 must be a positive integer without leading zeroes: %s\n' "$NodeID_hysteria2" >&2
    exit 1
    ;;
esac

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

chmod +x "$STAGE_DIR/startup.sh"
BACKUP_DIR="${INSTALL_DIR}.backup.$$"
rm -rf "$BACKUP_DIR"
if [ -d "$INSTALL_DIR" ]; then
  mv "$INSTALL_DIR" "$BACKUP_DIR"
fi
if ! mv "$STAGE_DIR" "$INSTALL_DIR"; then
  [ ! -d "$BACKUP_DIR" ] || mv "$BACKUP_DIR" "$INSTALL_DIR"
  printf '%s\n' '[ERROR] Could not activate the downloaded startup script.' >&2
  exit 1
fi

export NZ_SERVER NZ_TLS NZ_CLIENT_SECRET NZ_UUID \
  CFKEY CFUSER CFRECORD_NAME TG_BOT_TOKEN TG_USER_ID \
  ApiHost ApiKey NodeID_anytls NodeID_hysteria2
if ! "$INSTALL_DIR/startup.sh" install --yes; then
  if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    mv "$BACKUP_DIR" "$INSTALL_DIR"
    printf '%s\n' '[ERROR] Startup setup failed; the previous installation was restored.' >&2
  else
    printf '%s\n' '[ERROR] Startup setup is incomplete; installed files were kept for boot-time self-healing.' >&2
  fi
  exit 1
fi
rm -rf "$BACKUP_DIR"
