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
STARTUP_CFKEY="${CFKEY-}"
STARTUP_CFUSER="${CFUSER-}"
STARTUP_CFRECORD_NAME="${CFRECORD_NAME-}"
STARTUP_TG_BOT_TOKEN="${TG_BOT_TOKEN-}"
STARTUP_TG_USER_ID="${TG_USER_ID:-${TG_CHAT_ID:-${TG_USERID-}}}"
STARTUP_ApiHost="${ApiHost-}"
STARTUP_ApiKey="${ApiKey-}"
STARTUP_NodeID_anytls="${NodeID_anytls-}"
STARTUP_NodeID_hysteria2="${NodeID_hysteria2-}"
STARTUP_ENV_PATH=""

ACTION="install"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [command] [options]

Commands:
  install              Run all installation steps automatically (default)
  ddns                 Update the configured Cloudflare A record
  check                Detect the system and list available steps
  version              Print the script version
  wireproxy-ip         Check the VPS public IPv4 once
  wireproxy-ip-loop    Continuously check the VPS public IPv4 every 2 minutes
  help                 Show this help message

Options:
  --yes, -y            Compatibility option; install is always unattended
  --dry-run            Print commands without changing the system
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|check|version|help|ddns|ddns-loop|wireproxy-ip|wireproxy-ip-loop)
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

persist_startup_environment() {
  local config_path legacy_path input_path temp_path config_valid=0 has_input=0
  local saved_server="" saved_tls="" saved_client_secret="" saved_uuid=""
  local saved_install_url="" saved_installer_path=""
  local saved_cfkey="" saved_cfuser="" saved_cfrecord_name=""
  local saved_tg_bot_token="" saved_tg_user_id=""
  local saved_api_host="" saved_api_key=""
  local saved_node_id_anytls="" saved_node_id_hysteria2=""

  config_path="$STATE_DIR/startup.env"
  legacy_path="${STARTUP_NZ_CONFIG_PATH:-$STATE_DIR/nezha-agent.env}"
  input_path="$config_path"
  if [[ ! -r "$input_path" && -r "$legacy_path" ]]; then
    input_path="$legacy_path"
  fi
  STARTUP_ENV_PATH="$config_path"
  temp_path="${config_path}.$$"

  if [[ -r "$input_path" ]]; then
    if ! bash -n "$input_path" >/dev/null 2>&1 || ! source "$input_path"; then
      log_warn "The saved startup configuration is invalid. Replacing it."
      saved_server=""
      saved_tls=""
      saved_client_secret=""
      saved_uuid=""
      saved_install_url=""
      saved_installer_path=""
      saved_cfkey=""
      saved_cfuser=""
      saved_cfrecord_name=""
      saved_tg_bot_token=""
      saved_tg_user_id=""
      saved_api_host=""
      saved_api_key=""
      saved_node_id_anytls=""
      saved_node_id_hysteria2=""
    else
      config_valid=1
      saved_server="${NZ_SERVER:-}"
      saved_tls="${NZ_TLS:-}"
      saved_client_secret="${NZ_CLIENT_SECRET:-}"
      saved_uuid="${NZ_UUID:-}"
      saved_install_url="${NZ_INSTALL_URL:-}"
      saved_installer_path="${NZ_INSTALLER_PATH:-}"
      saved_cfkey="${CFKEY:-}"
      saved_cfuser="${CFUSER:-}"
      saved_cfrecord_name="${CFRECORD_NAME:-}"
      saved_tg_bot_token="${TG_BOT_TOKEN:-}"
      saved_tg_user_id="${TG_USER_ID:-${TG_CHAT_ID:-${TG_USERID:-}}}"
      saved_api_host="${ApiHost:-}"
      saved_api_key="${ApiKey:-}"
      saved_node_id_anytls="${NodeID_anytls:-}"
      saved_node_id_hysteria2="${NodeID_hysteria2:-}"
    fi
  fi

  if [[ -n "$STARTUP_NZ_SERVER$STARTUP_NZ_TLS$STARTUP_NZ_CLIENT_SECRET$STARTUP_NZ_UUID$STARTUP_NZ_INSTALL_URL$STARTUP_NZ_INSTALLER_PATH$STARTUP_CFKEY$STARTUP_CFUSER$STARTUP_CFRECORD_NAME$STARTUP_TG_BOT_TOKEN$STARTUP_TG_USER_ID$STARTUP_ApiHost$STARTUP_ApiKey$STARTUP_NodeID_anytls$STARTUP_NodeID_hysteria2" ]]; then
    has_input=1
  fi

  saved_server="${STARTUP_NZ_SERVER:-$saved_server}"
  saved_tls="${STARTUP_NZ_TLS:-${saved_tls:-true}}"
  saved_client_secret="${STARTUP_NZ_CLIENT_SECRET:-$saved_client_secret}"
  saved_uuid="${STARTUP_NZ_UUID:-$saved_uuid}"
  saved_install_url="${STARTUP_NZ_INSTALL_URL:-${saved_install_url:-https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh}}"
  saved_installer_path="${STARTUP_NZ_INSTALLER_PATH:-${saved_installer_path:-$STATE_DIR/agent.sh}}"
  saved_cfkey="${STARTUP_CFKEY:-$saved_cfkey}"
  saved_cfuser="${STARTUP_CFUSER:-$saved_cfuser}"
  saved_cfrecord_name="${STARTUP_CFRECORD_NAME:-$saved_cfrecord_name}"
  saved_tg_bot_token="${STARTUP_TG_BOT_TOKEN:-$saved_tg_bot_token}"
  saved_tg_user_id="${STARTUP_TG_USER_ID:-$saved_tg_user_id}"
  saved_api_host="${STARTUP_ApiHost:-$saved_api_host}"
  saved_api_key="${STARTUP_ApiKey:-$saved_api_key}"
  saved_node_id_anytls="${STARTUP_NodeID_anytls:-$saved_node_id_anytls}"
  saved_node_id_hysteria2="${STARTUP_NodeID_hysteria2:-$saved_node_id_hysteria2}"

  if [[ -z "$saved_server" || -z "$saved_client_secret" || -z "$saved_uuid" ]]; then
    log_error "NZ_SERVER, NZ_CLIENT_SECRET and NZ_UUID are required."
    return 1
  fi

  if [[ -z "$saved_cfkey" || -z "$saved_cfuser" || -z "$saved_cfrecord_name" ]]; then
    log_error "CFKEY, CFUSER and CFRECORD_NAME are required."
    return 1
  fi

  if [[ -z "$saved_api_host" || -z "$saved_api_key" ||
        -z "$saved_node_id_anytls" || -z "$saved_node_id_hysteria2" ]]; then
    log_error "ApiHost, ApiKey, NodeID_anytls and NodeID_hysteria2 are required."
    return 1
  fi

  if [[ ! "$saved_node_id_anytls" =~ ^[1-9][0-9]*$ ||
        ! "$saved_node_id_hysteria2" =~ ^[1-9][0-9]*$ ]]; then
    log_error "NodeID_anytls and NodeID_hysteria2 must be positive integers without leading zeroes."
    return 1
  fi

  if [[ -z "$saved_tg_bot_token" || -z "$saved_tg_user_id" ]]; then
    log_error "TG_BOT_TOKEN and TG_USER_ID are required."
    return 1
  fi

  NZ_SERVER="$saved_server"
  NZ_TLS="$saved_tls"
  NZ_CLIENT_SECRET="$saved_client_secret"
  NZ_UUID="$saved_uuid"
  NZ_INSTALL_URL="$saved_install_url"
  NZ_INSTALLER_PATH="$saved_installer_path"
  STARTUP_NZ_SERVER="$saved_server"
  STARTUP_NZ_TLS="$saved_tls"
  STARTUP_NZ_CLIENT_SECRET="$saved_client_secret"
  STARTUP_NZ_UUID="$saved_uuid"
  STARTUP_NZ_INSTALL_URL="$saved_install_url"
  STARTUP_NZ_INSTALLER_PATH="$saved_installer_path"
  CFKEY="$saved_cfkey"
  CFUSER="$saved_cfuser"
  CFRECORD_NAME="$saved_cfrecord_name"
  TG_BOT_TOKEN="$saved_tg_bot_token"
  TG_USER_ID="$saved_tg_user_id"
  ApiHost="$saved_api_host"
  ApiKey="$saved_api_key"
  NodeID_anytls="$saved_node_id_anytls"
  NodeID_hysteria2="$saved_node_id_hysteria2"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "$has_input" == "0" && "$config_valid" == "1" && "$input_path" == "$config_path" ]]; then
    chmod 0600 "$config_path" || {
      log_error "Could not protect the saved startup configuration."
      return 1
    }
    return 0
  fi

  if ! mkdir -p "$(dirname -- "$config_path")"; then
    log_error "Could not create the startup configuration directory."
    return 1
  fi

  umask 077
  if ! printf 'NZ_SERVER=%q\nNZ_TLS=%q\nNZ_CLIENT_SECRET=%q\nNZ_UUID=%q\nNZ_INSTALL_URL=%q\nNZ_INSTALLER_PATH=%q\nCFKEY=%q\nCFUSER=%q\nCFRECORD_NAME=%q\nTG_BOT_TOKEN=%q\nTG_USER_ID=%q\nApiHost=%q\nApiKey=%q\nNodeID_anytls=%q\nNodeID_hysteria2=%q\n' \
    "$saved_server" "$saved_tls" "$saved_client_secret" "$saved_uuid" "$saved_install_url" "$saved_installer_path" \
    "$saved_cfkey" "$saved_cfuser" "$saved_cfrecord_name" "$saved_tg_bot_token" "$saved_tg_user_id" \
    "$saved_api_host" "$saved_api_key" "$saved_node_id_anytls" "$saved_node_id_hysteria2" > "$temp_path"; then
    rm -f "$temp_path"
    log_error "Could not write the startup configuration."
    return 1
  fi

  if ! chmod 0600 "$temp_path" || ! mv -f "$temp_path" "$config_path"; then
    rm -f "$temp_path"
    log_error "Could not save the startup configuration."
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
      fi
      if ! persist_startup_environment; then
        return 1
      fi
      detect_system
      print_system_info
      require_supported_system
      if ! ensure_boot_service; then
        log_error "Boot service registration failed."
        return 1
      fi
      list_steps
      run_steps
      log_success "All steps are healthy."
      ;;
    ddns)
      prepare_noninteractive
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
      persist_startup_environment
      source "$SCRIPT_DIR/steps/04_cloudflare_ddns.sh"
      cf_ddns_sync
      ;;
    ddns-loop)
      prepare_noninteractive
      require_root
      while true; do
        "$SCRIPT_DIR/startup.sh" ddns || true
        sleep 300
      done
      ;;
    wireproxy-ip)
      prepare_noninteractive
      require_root
      init_runtime
      persist_startup_environment
      source "$SCRIPT_DIR/steps/05_warp_wireproxy.sh"
      wireproxy_ip_check
      ;;
    wireproxy-ip-loop)
      prepare_noninteractive
      require_root
      init_runtime
      persist_startup_environment
      source "$SCRIPT_DIR/steps/05_warp_wireproxy.sh"
      wireproxy_ip_loop
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
