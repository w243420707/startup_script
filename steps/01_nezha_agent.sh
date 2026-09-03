#!/usr/bin/env bash

STEP_ID="01"
STEP_NAME="Nezha agent"
STEP_DESCRIPTION="Install and keep the Nezha monitoring agent running."

NZ_CONFIG_PATH="${STARTUP_NZ_CONFIG_PATH:-${NZ_CONFIG_PATH:-$STATE_DIR/nezha-agent.env}}"
NZ_ENV_SERVER="${STARTUP_NZ_SERVER:-}"
NZ_ENV_TLS="${STARTUP_NZ_TLS:-}"
NZ_ENV_CLIENT_SECRET="${STARTUP_NZ_CLIENT_SECRET:-}"
NZ_ENV_UUID="${STARTUP_NZ_UUID:-}"
NZ_ENV_INSTALL_URL="${STARTUP_NZ_INSTALL_URL:-}"
NZ_ENV_INSTALLER_PATH="${STARTUP_NZ_INSTALLER_PATH:-}"

if [[ -r "$NZ_CONFIG_PATH" ]]; then
  if bash -n "$NZ_CONFIG_PATH" >/dev/null 2>&1 && source "$NZ_CONFIG_PATH"; then
    :
  else
    log_warn "The saved Nezha configuration is invalid. Rebuilding it."
  fi
fi

NZ_SERVER="${NZ_ENV_SERVER:-${NZ_SERVER:-tz.114431.xyz:443}}"
NZ_TLS="${NZ_ENV_TLS:-${NZ_TLS:-true}}"
NZ_CLIENT_SECRET="${NZ_ENV_CLIENT_SECRET:-${NZ_CLIENT_SECRET:-}}"
NZ_UUID="${NZ_ENV_UUID:-${NZ_UUID:-}}"
NZ_INSTALL_URL="${NZ_ENV_INSTALL_URL:-${NZ_INSTALL_URL:-https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh}}"
NZ_INSTALLER_PATH="${NZ_ENV_INSTALLER_PATH:-${NZ_INSTALLER_PATH:-$STATE_DIR/agent.sh}}"
NZ_AGENT_BINARY="/opt/nezha/agent/nezha-agent"
NZ_APPLIED_CONFIG_PATH="$STATE_DIR/nezha-agent.applied"
NZ_SERVICE_NAME="nezha-agent"

nz_service_exists() {
  [[ -d /run/systemd/system ]] && command_exists systemctl && systemctl cat "${NZ_SERVICE_NAME}.service" >/dev/null 2>&1
}

nz_service_running() {
  if nz_service_exists; then
    systemctl is-active --quiet "$NZ_SERVICE_NAME"
    return $?
  fi

  if command_exists rc-service && rc-service "$NZ_SERVICE_NAME" status >/dev/null 2>&1; then
    return 0
  fi

  if command_exists service && service "$NZ_SERVICE_NAME" status >/dev/null 2>&1; then
    return 0
  fi

  if [[ -x "$NZ_AGENT_BINARY" ]] && command_exists pidof; then
    pidof nezha-agent >/dev/null 2>&1
    return $?
  fi

  return 1
}

print_nz_config() {
  printf 'NZ_SERVER=%q\nNZ_TLS=%q\nNZ_CLIENT_SECRET=%q\nNZ_UUID=%q\nNZ_INSTALL_URL=%q\nNZ_INSTALLER_PATH=%q\n' \
    "$NZ_SERVER" "$NZ_TLS" "$NZ_CLIENT_SECRET" "$NZ_UUID" "$NZ_INSTALL_URL" "$NZ_INSTALLER_PATH"
}

desired_config_signature() {
  local checksum size

  if ! read -r checksum size _ < <(print_nz_config | cksum) ||
     [[ -z "$checksum" || -z "$size" ]]; then
    return 1
  fi

  printf '%s:%s\n' "$checksum" "$size"
}

config_is_applied() {
  local applied_signature desired_signature
  [[ -r "$NZ_APPLIED_CONFIG_PATH" ]] || return 1
  read -r applied_signature < "$NZ_APPLIED_CONFIG_PATH" || return 1
  desired_signature="$(desired_config_signature)" || return 1
  [[ "$applied_signature" == "$desired_signature" ]]
}

mark_config_applied() {
  local temp_path="${NZ_APPLIED_CONFIG_PATH}.$$"

  umask 077
  if ! desired_config_signature > "$temp_path"; then
    rm -f "$temp_path"
    return 1
  fi

  if ! chmod 0600 "$temp_path" || ! mv -f "$temp_path" "$NZ_APPLIED_CONFIG_PATH"; then
    rm -f "$temp_path"
    return 1
  fi
}

step_check() {
  if [[ ! -x "$NZ_AGENT_BINARY" ]] || ! nz_service_running; then
    return 1
  fi

  [[ -r "$NZ_CONFIG_PATH" ]] && config_is_applied
}

write_nz_config() {
  local temp_path="${NZ_CONFIG_PATH}.$$"

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  if ! mkdir -p "$(dirname -- "$NZ_CONFIG_PATH")"; then
    return 1
  fi

  umask 077
  if ! print_nz_config > "$temp_path"; then
    rm -f "$temp_path"
    return 1
  fi

  if ! chmod 0600 "$temp_path" || ! mv -f "$temp_path" "$NZ_CONFIG_PATH"; then
    rm -f "$temp_path"
    return 1
  fi
}

ensure_nz_installer() {
  local temp_path="${NZ_INSTALLER_PATH}.$$"
  local cache_is_valid=0

  if [[ -s "$NZ_INSTALLER_PATH" ]] && bash -n "$NZ_INSTALLER_PATH" >/dev/null 2>&1; then
    cache_is_valid=1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    run_cmd curl -fL --connect-timeout 15 --max-time 120 "$NZ_INSTALL_URL" -o "$NZ_INSTALLER_PATH"
    return 0
  fi

  if ! mkdir -p "$(dirname -- "$NZ_INSTALLER_PATH")"; then
    return 1
  fi

  if ! run_with_retries "$COMMAND_RETRIES" curl -fL --connect-timeout 15 --max-time 120 "$NZ_INSTALL_URL" -o "$temp_path"; then
    rm -f "$temp_path"
    if [[ "$cache_is_valid" == "1" ]]; then
      log_warn "Could not refresh the Nezha installer. Using the valid cached copy."
      return 0
    fi
    return 1
  fi

  if [[ ! -s "$temp_path" ]] || ! bash -n "$temp_path" >/dev/null 2>&1; then
    rm -f "$temp_path"
    if [[ "$cache_is_valid" == "1" ]]; then
      log_warn "The refreshed Nezha installer is invalid. Using the valid cached copy."
      return 0
    fi
    log_error "The downloaded Nezha installer is not valid Bash."
    return 1
  fi

  if ! chmod 0700 "$temp_path" || ! mv -f "$temp_path" "$NZ_INSTALLER_PATH"; then
    rm -f "$temp_path"
    return 1
  fi
}

run_nz_installer() {
  local -a installer_command=(bash "$NZ_INSTALLER_PATH")

  if command_exists timeout; then
    installer_command=(timeout 600 bash "$NZ_INSTALLER_PATH")
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "Nezha server: $NZ_SERVER, TLS: $NZ_TLS, UUID: $NZ_UUID"
    log_info "The client secret is intentionally hidden from logs."
    run_cmd "${installer_command[@]}"
    return $?
  fi

  (
    export NZ_SERVER NZ_TLS NZ_CLIENT_SECRET NZ_UUID
    run_with_retries "$COMMAND_RETRIES" "${installer_command[@]}"
  )
}

start_nz_service() {
  if nz_service_exists; then
    run_with_retries "$COMMAND_RETRIES" systemctl enable --now "$NZ_SERVICE_NAME"
    return $?
  fi

  if command_exists rc-service; then
    if command_exists rc-update && ! run_with_retries "$COMMAND_RETRIES" rc-update add "$NZ_SERVICE_NAME" default; then
      return 1
    fi
    run_with_retries "$COMMAND_RETRIES" rc-service "$NZ_SERVICE_NAME" start
    return $?
  fi

  if command_exists service; then
    run_with_retries "$COMMAND_RETRIES" service "$NZ_SERVICE_NAME" start
    return $?
  fi

  if [[ -x "$NZ_AGENT_BINARY" ]] && command_exists pidof && pidof nezha-agent >/dev/null 2>&1; then
    return 0
  fi

  log_warn "Nezha installer did not register a recognized service."
  return 1
}

wait_for_nz_service() {
  local attempt

  for ((attempt = 1; attempt <= 10; attempt++)); do
    if nz_service_running; then
      return 0
    fi
    sleep 2
  done

  return 1
}

step_repair() {
  if [[ -z "$NZ_SERVER" || -z "$NZ_TLS" || -z "$NZ_CLIENT_SECRET" || -z "$NZ_UUID" ]]; then
    log_error "Nezha agent variables are incomplete."
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    ensure_nz_installer
    run_nz_installer
    return $?
  fi

  if ! write_nz_config; then
    log_error "Could not save the Nezha agent configuration."
    return 1
  fi

  if config_is_applied && start_nz_service && wait_for_nz_service; then
    log_success "Existing Nezha agent service is running."
    return 0
  fi

  if ! ensure_nz_installer; then
    log_error "Could not download or validate the Nezha installer."
    return 1
  fi

  if ! run_nz_installer; then
    log_error "Nezha agent installation failed."
    return 1
  fi

  if ! start_nz_service || ! wait_for_nz_service; then
    log_error "Nezha agent installation completed, but its service is not healthy."
    return 1
  fi

  if ! mark_config_applied; then
    log_error "Nezha agent is healthy, but its applied configuration state could not be saved."
    return 1
  fi
}
