#!/usr/bin/env bash

SCRIPT_NAME="${SCRIPT_NAME:-startup-script}"
STATE_DIR="${STARTUP_SCRIPT_STATE_DIR:-/var/lib/startup-script}"
LOG_FILE="${STARTUP_SCRIPT_LOG_FILE:-/root/startup-script.log}"
LOCK_FILE="${STARTUP_SCRIPT_LOCK_FILE:-/run/startup-script.lock}"
COMMAND_RETRIES="${STARTUP_SCRIPT_COMMAND_RETRIES:-3}"
STEP_RETRIES="${STARTUP_SCRIPT_STEP_RETRIES:-2}"
RETRY_DELAY_SECONDS="${STARTUP_SCRIPT_RETRY_DELAY_SECONDS:-5}"

if [[ -t 1 ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_BOLD=$'\033[1m'
  COLOR_BLUE=$'\033[34m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_RED=$'\033[31m'
else
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_BLUE=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_RED=""
fi

log_info() {
  printf '%s[INFO]%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

log_success() {
  printf '%s[OK]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

log_error() {
  printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "This action must be run as root. Use sudo or switch to root."
    return 1
  fi
}

prepare_noninteractive() {
  export DEBIAN_FRONTEND=noninteractive
  export APT_LISTCHANGES_FRONTEND=none
  export NEEDRESTART_MODE=a
}

init_runtime() {
  local log_dir

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  log_dir="$(dirname -- "$LOG_FILE")"

  if ! mkdir -p "$STATE_DIR" "$log_dir" || ! touch "$LOG_FILE" || ! chmod 0600 "$LOG_FILE"; then
    STATE_DIR="/tmp/startup-script"
    LOG_FILE="/tmp/startup-script.log"
    if ! mkdir -p "$STATE_DIR" /tmp || ! touch "$LOG_FILE" || ! chmod 0600 "$LOG_FILE"; then
      LOG_FILE="/dev/null"
    else
      log_warn "Could not use the configured runtime paths. Falling back to /tmp."
    fi
  fi

  if [[ -f "$LOG_FILE" ]] && [[ "$(wc -c < "$LOG_FILE")" -gt 5242880 ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" || true
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE" || true
  fi

  if ! exec >> "$LOG_FILE" 2>&1; then
    LOG_FILE="/dev/null"
    exec >> "$LOG_FILE" 2>&1
  fi
  log_info "$SCRIPT_NAME $VERSION started (pid $$)."
}

acquire_lock() {
  local lock_dir old_pid

  if command_exists flock; then
    if ! exec {LOCK_FD}>"$LOCK_FILE"; then
      LOCK_FILE="$STATE_DIR/startup-script.lock"
      if ! exec {LOCK_FD}>"$LOCK_FILE"; then
        log_warn "Could not create the startup-script lock. Exiting."
        return 1
      fi
    fi
    if ! flock -n "$LOCK_FD"; then
      log_warn "Another startup-script process is already running. Exiting."
      return 2
    fi
    LOCK_MODE="flock"
    return 0
  fi

  lock_dir="${LOCK_FILE}.d"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [[ ! -d "$lock_dir" ]]; then
      lock_dir="$STATE_DIR/startup-script.lock.d"
      if mkdir "$lock_dir" 2>/dev/null; then
        if ! printf '%s\n' "$$" > "$lock_dir/pid"; then
          rmdir "$lock_dir" 2>/dev/null || true
          log_warn "Could not write the fallback startup-script lock. Exiting."
          return 1
        fi
        LOCK_MODE="mkdir"
        LOCK_DIR="$lock_dir"
        return 0
      fi
      log_warn "Could not create the fallback startup-script lock. Exiting."
      return 1
    fi

    old_pid=""
    if [[ -r "$lock_dir/pid" ]]; then
      read -r old_pid < "$lock_dir/pid" || true
    fi
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log_warn "Another startup-script process is already running (pid $old_pid). Exiting."
      return 2
    fi
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
    if ! mkdir "$lock_dir" 2>/dev/null; then
      log_warn "Could not acquire the fallback lock. Exiting."
      return 1
    fi
  fi

  if ! printf '%s\n' "$$" > "$lock_dir/pid"; then
    rmdir "$lock_dir" 2>/dev/null || true
    log_warn "Could not write the startup-script lock. Exiting."
    return 1
  fi
  LOCK_MODE="mkdir"
  LOCK_DIR="$lock_dir"
}

release_lock() {
  case "${LOCK_MODE:-}" in
    mkdir)
      rm -f "${LOCK_DIR:-}/pid"
      rmdir "${LOCK_DIR:-}" 2>/dev/null || true
      ;;
    flock)
      if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
      fi
      ;;
  esac
}

run_cmd() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

run_with_retries() {
  local attempts="${1:-$COMMAND_RETRIES}"
  local delay="${RETRY_DELAY_SECONDS}"
  local attempt

  if ! [[ "$delay" =~ ^[0-9]+$ ]]; then
    delay=5
  else
    delay=$((10#$delay))
    if (( delay > 300 )); then
      delay=5
    fi
  fi
  shift

  if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
    attempts=1
  else
    attempts=$((10#$attempts))
    if (( attempts < 1 )); then
      attempts=1
    elif (( attempts > 10 )); then
      attempts=10
    fi
  fi

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if run_cmd "$@"; then
      return 0
    fi

    if (( attempt < attempts )); then
      log_warn "Command failed (attempt $attempt/$attempts): $*"
      sleep "$delay"
      if (( delay < 300 )); then
        delay=$((delay * 2))
        if (( delay > 300 )); then
          delay=300
        fi
      fi
    fi
  done

  log_error "Command failed after $attempts attempts: $*"
  return 1
}

state_file_for_step() {
  printf '%s/%s.state\n' "$STATE_DIR" "$1"
}

write_step_state() {
  local step_id="$1"
  local state_file temp_file

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  state_file="$(state_file_for_step "$step_id")"
  temp_file="${state_file}.$$"
  printf 'status=ok\nversion=%s\ntime=%s\n' "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$temp_file"
  mv -f "$temp_file" "$state_file"
}

on_unexpected_error() {
  local exit_code="$?"
  log_error "Unexpected failure at line $1 (exit code $exit_code)."
  return "$exit_code"
}
