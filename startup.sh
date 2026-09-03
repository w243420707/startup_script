#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
  install_bash() {
    attempt=1
    while [ "$attempt" -le 3 ]; do
      if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash
      elif command -v apt-get >/dev/null 2>&1; then
        dpkg --force-confold --configure -a >/dev/null 2>&1 || true
        apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold update && apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold install -y bash
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash
      elif command -v yum >/dev/null 2>&1; then
        yum install -y bash
      elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm bash
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install -y bash
      else
        return 1
      fi

      if command -v bash >/dev/null 2>&1; then
        return 0
      fi

      sleep $((attempt * 5))
      attempt=$((attempt + 1))
    done

    return 1
  }

  if ! command -v bash >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none
    export NEEDRESTART_MODE=a
    if ! install_bash; then
      printf '%s\n' '[ERROR] Bash is required but could not be installed.' >&2
      exit 1
    fi
  fi

  exec bash "$0" "$@"
fi

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="startup-script"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION" 2>/dev/null || printf 'dev')"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/system.sh"
source "$SCRIPT_DIR/lib/boot.sh"

STARTUP_NZ_SERVER="${NZ_SERVER-}"
STARTUP_NZ_TLS="${NZ_TLS-}"
STARTUP_NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET-}"
STARTUP_NZ_UUID="${NZ_UUID-}"
STARTUP_NZ_INSTALL_URL="${NZ_INSTALL_URL-}"
STARTUP_NZ_INSTALLER_PATH="${NZ_INSTALLER_PATH-}"
STARTUP_NZ_CONFIG_PATH="${NZ_CONFIG_PATH-}"

ACTION="install"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [command] [options]

Commands:
  install              Run all installation steps automatically (default)
  check                Detect the system and list available steps
  version              Print the script version
  help                 Show this help message

Options:
  --yes, -y            Compatibility option; install is always unattended
  --dry-run            Print commands without changing the system
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|check|version|help)
        ACTION="$1"
        ;;
      --yes|-y)
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --help|-h)
        ACTION="help"
        ;;
      *)
        log_error "Unknown argument: $1"
        usage
        return 1
        ;;
    esac
    shift
  done
}

persist_nezha_environment() {
  local config_path temp_path
  local saved_server="" saved_tls="" saved_client_secret="" saved_uuid=""
  local saved_install_url="" saved_installer_path=""

  if [[ -z "$STARTUP_NZ_SERVER" &&
        -z "$STARTUP_NZ_TLS" &&
        -z "$STARTUP_NZ_CLIENT_SECRET" &&
        -z "$STARTUP_NZ_UUID" &&
        -z "$STARTUP_NZ_INSTALL_URL" &&
        -z "$STARTUP_NZ_INSTALLER_PATH" &&
        -z "$STARTUP_NZ_CONFIG_PATH" ]]; then
    return 0
  fi

  config_path="${STARTUP_NZ_CONFIG_PATH:-$STATE_DIR/nezha-agent.env}"
  temp_path="${config_path}.$$"

  if [[ -r "$config_path" ]]; then
    if ! bash -n "$config_path" >/dev/null 2>&1 || ! source "$config_path"; then
      log_warn "The saved Nezha configuration is invalid. Replacing it."
      saved_server=""
      saved_tls=""
      saved_client_secret=""
      saved_uuid=""
      saved_install_url=""
      saved_installer_path=""
    else
      saved_server="${NZ_SERVER:-}"
      saved_tls="${NZ_TLS:-}"
      saved_client_secret="${NZ_CLIENT_SECRET:-}"
      saved_uuid="${NZ_UUID:-}"
      saved_install_url="${NZ_INSTALL_URL:-}"
      saved_installer_path="${NZ_INSTALLER_PATH:-}"
    fi
  fi

  saved_server="${STARTUP_NZ_SERVER:-$saved_server}"
  saved_tls="${STARTUP_NZ_TLS:-${saved_tls:-true}}"
  saved_client_secret="${STARTUP_NZ_CLIENT_SECRET:-$saved_client_secret}"
  saved_uuid="${STARTUP_NZ_UUID:-$saved_uuid}"
  saved_install_url="${STARTUP_NZ_INSTALL_URL:-${saved_install_url:-https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh}}"
  saved_installer_path="${STARTUP_NZ_INSTALLER_PATH:-${saved_installer_path:-$STATE_DIR/agent.sh}}"

  if [[ -z "$saved_server" || -z "$saved_client_secret" || -z "$saved_uuid" ]]; then
    log_error "NZ_SERVER, NZ_CLIENT_SECRET and NZ_UUID are required."
    return 1
  fi

  if ! mkdir -p "$(dirname -- "$config_path")"; then
    log_error "Could not create the Nezha configuration directory."
    return 1
  fi

  umask 077
  if ! printf 'NZ_SERVER=%q\nNZ_TLS=%q\nNZ_CLIENT_SECRET=%q\nNZ_UUID=%q\nNZ_INSTALL_URL=%q\nNZ_INSTALLER_PATH=%q\n' \
    "$saved_server" "$saved_tls" "$saved_client_secret" "$saved_uuid" "$saved_install_url" "$saved_installer_path" > "$temp_path"; then
    rm -f "$temp_path"
    log_error "Could not write the Nezha configuration."
    return 1
  fi

  if ! chmod 0600 "$temp_path" || ! mv -f "$temp_path" "$config_path"; then
    rm -f "$temp_path"
    log_error "Could not save the Nezha configuration."
    return 1
  fi
}

list_steps() {
  local step_file step_id step_name step_description
  local -a step_files=()
  shopt -s nullglob
  step_files=("$SCRIPT_DIR"/steps/*.sh)
  shopt -u nullglob

  if [[ "${#step_files[@]}" -eq 0 ]]; then
    log_warn "No installation steps found."
    return 0
  fi

  printf 'Installation steps\n'
  printf '%s\n' "------------------"
  for step_file in "${step_files[@]}"; do
    unset STEP_ID STEP_NAME STEP_DESCRIPTION
    unset -f step_check step_repair 2>/dev/null || true
    source "$step_file"
    step_id="${STEP_ID:-??}"
    step_name="${STEP_NAME:-Unnamed step}"
    step_description="${STEP_DESCRIPTION:-No description.}"
    printf '%s. %s - %s\n' "$step_id" "$step_name" "$step_description"
  done
  printf '\n'
}

run_step() {
  local step_file="$1"
  local step_id step_name step_description state_file

  unset STEP_ID STEP_NAME STEP_DESCRIPTION
  unset -f step_check step_repair 2>/dev/null || true
  source "$step_file"
  step_id="${STEP_ID:-??}"
  step_name="${STEP_NAME:-Unnamed step}"
  step_description="${STEP_DESCRIPTION:-No description.}"
  state_file="$(state_file_for_step "$step_id")"

  if ! declare -F step_check >/dev/null || ! declare -F step_repair >/dev/null; then
    log_error "Step $step_id must define both step_check and step_repair."
    return 1
  fi

  printf '\n[%s] %s\n%s\n' "$step_id" "$step_name" "$step_description"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "Dry-run mode: showing the repair commands only."
    step_repair
    return $?
  fi

  if [[ "${FORCE_RUN:-0}" != "1" ]] && [[ -r "$state_file" ]]; then
    log_info "Step $step_id was completed before. Checking it again."
  fi

  if step_check; then
    write_step_state "$step_id"
    log_success "Step $step_id is healthy."
    return 0
  fi

  log_warn "Step $step_id needs repair."
  if step_repair; then
    if step_check; then
      write_step_state "$step_id"
      log_success "Step $step_id repaired successfully."
      return 0
    fi
  fi

  log_error "Step $step_id could not be repaired."
  return 1
}

run_steps() {
  local step_file
  local -a step_files=()
  shopt -s nullglob
  step_files=("$SCRIPT_DIR"/steps/*.sh)
  shopt -u nullglob

  if [[ "$DRY_RUN" == "1" ]]; then
    for step_file in "${step_files[@]}"; do
      if ! run_step "$step_file"; then
        return 1
      fi
    done
    return 0
  fi

  for step_file in "${step_files[@]}"; do
    if ! run_with_retries "$STEP_RETRIES" run_step "$step_file"; then
      log_error "Stopping after step failure. It will be retried on the next boot."
      return 1
    fi
  done
}

main() {
  parse_args "$@"

  case "$ACTION" in
    help)
      usage
      ;;
    version)
      printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
      ;;
    check)
      detect_system
      print_system_info
      list_steps
      require_supported_system
      ;;
    install)
      prepare_noninteractive
      if [[ "$DRY_RUN" != "1" ]]; then
        require_root
        init_runtime
        local lock_status=0
        acquire_lock || lock_status="$?"
        if [[ "$lock_status" == "2" ]]; then
          return 0
        elif [[ "$lock_status" != "0" ]]; then
          return "$lock_status"
        fi
        trap 'release_lock' EXIT
        trap 'on_unexpected_error $LINENO' ERR
        if ! persist_nezha_environment; then
          return 1
        fi
      fi
      detect_system
      print_system_info
      require_supported_system
      if ! ensure_boot_service; then
        log_warn "Boot service registration failed. Continuing with the current repair run."
      fi
      list_steps
      run_steps
      log_success "All steps are healthy."
      ;;
  esac
}

main "$@"
