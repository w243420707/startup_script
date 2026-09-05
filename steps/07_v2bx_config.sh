#!/usr/bin/env bash

STEP_ID="07"
STEP_NAME="V2bX configuration"
STEP_DESCRIPTION="Generate the V2bX node configuration, start its service, and keep it running with a watchdog."

V2BX_CONFIG_TEMPLATE="$SCRIPT_DIR/example/config.json"
V2BX_SING_TEMPLATE="$SCRIPT_DIR/example/sing_origin.json"
V2BX_BINARY="/usr/local/V2bX/V2bX"
V2BX_CONFIG_DIR="/etc/V2bX"
V2BX_CONFIG_PATH="$V2BX_CONFIG_DIR/config.json"
V2BX_SING_PATH="$V2BX_CONFIG_DIR/sing_origin.json"
V2BX_WATCHDOG_SYSTEMD_SERVICE="/etc/systemd/system/startup-v2bx-watchdog.service"
V2BX_WATCHDOG_SYSTEMD_TIMER="/etc/systemd/system/startup-v2bx-watchdog.timer"
V2BX_WATCHDOG_OPENRC_SERVICE="/etc/init.d/startup-v2bx-watchdog"
V2BX_WATCHDOG_INTERVAL_SECONDS="60"

v2bx_variables_valid() {
  [[ -n "${ApiHost:-}" && -n "${ApiKey:-}" ]] &&
    [[ "${ApiHost:-}" =~ ^https?://[^[:space:]]+$ ]] &&
    [[ "${NodeID_anytls:-}" =~ ^[1-9][0-9]*$ ]] &&
    [[ "${NodeID_hysteria2:-}" =~ ^[1-9][0-9]*$ ]]
}

v2bx_config_matches() {
  [[ -r "$V2BX_CONFIG_PATH" && -r "$V2BX_SING_PATH" ]] || return 1
  jq -e \
    --arg api_host "$ApiHost" \
    --rawfile api_key <(printf '%s' "$ApiKey") \
    --argjson anytls_id "$NodeID_anytls" \
    --argjson hysteria2_id "$NodeID_hysteria2" \
    '.Cores[0].OriginalPath == "/etc/V2bX/sing_origin.json" and
     .Nodes[0].ApiHost == $api_host and
     .Nodes[1].ApiHost == $api_host and
     .Nodes[0].ApiKey == $api_key and
     .Nodes[1].ApiKey == $api_key and
     .Nodes[0].NodeID == $anytls_id and
     .Nodes[1].NodeID == $hysteria2_id and
     .Nodes[0].NodeType == "anytls" and
     .Nodes[1].NodeType == "hysteria2"' \
    "$V2BX_CONFIG_PATH" >/dev/null 2>&1 &&
    cmp -s "$V2BX_SING_TEMPLATE" "$V2BX_SING_PATH"
}

v2bx_service_running() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-active --quiet V2bX.service
    return $?
  fi

  if command_exists rc-service && [[ -x /etc/init.d/V2bX ]]; then
    rc-service V2bX status >/dev/null 2>&1
    return $?
  fi

  return 1
}

v2bx_service_enabled() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-enabled --quiet V2bX.service
    return $?
  fi

  if command_exists rc-update; then
    rc-update show 2>/dev/null | grep -Eq '^[[:space:]]*V2bX[[:space:]]'
    return $?
  fi

  return 1
}

v2bx_start_service() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    run_with_retries "$COMMAND_RETRIES" systemctl daemon-reload &&
      run_with_retries "$COMMAND_RETRIES" systemctl enable V2bX.service &&
      run_with_retries "$COMMAND_RETRIES" systemctl restart V2bX.service
    return $?
  fi

  if command_exists rc-service && command_exists rc-update && [[ -x /etc/init.d/V2bX ]]; then
    run_with_retries "$COMMAND_RETRIES" rc-update add V2bX default &&
      run_with_retries "$COMMAND_RETRIES" rc-service V2bX restart
    return $?
  fi

  return 1
}

v2bx_wait_running() {
  local attempt

  for ((attempt = 1; attempt <= 10; attempt++)); do
    if v2bx_service_running; then
      sleep 2
      v2bx_service_running && return 0
    fi
    sleep 2
  done

  return 1
}

v2bx_recover_service() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl reset-failed V2bX.service >/dev/null 2>&1 || true
    run_with_retries "$COMMAND_RETRIES" systemctl start V2bX.service
    return $?
  fi

  if command_exists rc-service && [[ -x /etc/init.d/V2bX ]]; then
    run_with_retries "$COMMAND_RETRIES" rc-service V2bX restart
    return $?
  fi

  log_error "V2bX cannot be started because no supported service manager is available."
  return 1
}

v2bx_watchdog_once() {
  if v2bx_service_running; then
    return 0
  fi

  if [[ ! -x "$V2BX_BINARY" || ! -r "$V2BX_CONFIG_PATH" || ! -r "$V2BX_SING_PATH" ]]; then
    log_error "V2bX is down, but its executable or configuration is missing."
    return 1
  fi

  log_warn "V2bX is not running. Starting it now."
  v2bx_recover_service || return 1
  v2bx_wait_running || {
    log_error "V2bX did not recover after the watchdog start attempt."
    return 1
  }
  log_success "V2bX was started by the watchdog."
}

v2bx_watchdog_loop() {
  while true; do
    sleep "$V2BX_WATCHDOG_INTERVAL_SECONDS"
    "$SCRIPT_DIR/startup.sh" v2bx-watchdog || true
  done
}

v2bx_watchdog_systemd_service_contents() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  cat <<EOF
[Unit]
Description=Start V2bX when it is not running
Wants=network-online.target
After=network-online.target startup-script.service

[Service]
Type=oneshot
ExecStart=$bash_path $script_path v2bx-watchdog
EOF
}

v2bx_watchdog_systemd_timer_contents() {
  cat <<'EOF'
[Unit]
Description=Check V2bX service health every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
}

v2bx_watchdog_openrc_service_contents() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  cat <<EOF
#!/sbin/openrc-run

name="startup-v2bx-watchdog"
description="Start V2bX when it is not running"
command="$bash_path"
command_args="$script_path v2bx-watchdog-loop"
command_background="yes"
pidfile="/run/startup-v2bx-watchdog.pid"
depend() { need net; after V2bX local; }
EOF
}

v2bx_watchdog_install_generated_file() {
  local path="$1"
  local mode="$2"
  local generator="$3"
  local temp_path="${path}.$$"

  "$generator" > "$temp_path" || {
    rm -f "$temp_path"
    return 1
  }

  if [[ -f "$path" ]] && cmp -s "$temp_path" "$path"; then
    rm -f "$temp_path"
    return 0
  fi

  chmod "$mode" "$temp_path" && mv -f "$temp_path" "$path"
}

v2bx_watchdog_systemd_matches() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  [[ -r "$V2BX_WATCHDOG_SYSTEMD_SERVICE" ]] &&
    grep -Fqx "ExecStart=$bash_path $script_path v2bx-watchdog" "$V2BX_WATCHDOG_SYSTEMD_SERVICE" &&
    [[ -r "$V2BX_WATCHDOG_SYSTEMD_TIMER" ]] &&
    grep -Fqx 'OnUnitActiveSec=1min' "$V2BX_WATCHDOG_SYSTEMD_TIMER"
}

v2bx_watchdog_scheduler_healthy() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    v2bx_watchdog_systemd_matches &&
      systemctl is-enabled --quiet startup-v2bx-watchdog.timer &&
      systemctl is-active --quiet startup-v2bx-watchdog.timer
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    [[ -x "$V2BX_WATCHDOG_OPENRC_SERVICE" ]] &&
      grep -Fqx 'command_args="'"$SCRIPT_DIR"'/startup.sh v2bx-watchdog-loop"' "$V2BX_WATCHDOG_OPENRC_SERVICE" &&
      rc-update show 2>/dev/null | grep -Eq '^[[:space:]]*startup-v2bx-watchdog[[:space:]]' &&
      rc-service startup-v2bx-watchdog status >/dev/null 2>&1
    return $?
  fi

  return 1
}

v2bx_watchdog_install_scheduler() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    v2bx_watchdog_install_generated_file "$V2BX_WATCHDOG_SYSTEMD_SERVICE" 0644 v2bx_watchdog_systemd_service_contents &&
      v2bx_watchdog_install_generated_file "$V2BX_WATCHDOG_SYSTEMD_TIMER" 0644 v2bx_watchdog_systemd_timer_contents &&
      run_with_retries "$COMMAND_RETRIES" systemctl daemon-reload &&
      run_with_retries "$COMMAND_RETRIES" systemctl enable startup-v2bx-watchdog.timer &&
      run_with_retries "$COMMAND_RETRIES" systemctl restart startup-v2bx-watchdog.timer
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    v2bx_watchdog_install_generated_file "$V2BX_WATCHDOG_OPENRC_SERVICE" 0755 v2bx_watchdog_openrc_service_contents &&
      run_with_retries "$COMMAND_RETRIES" rc-update add startup-v2bx-watchdog default &&
      run_with_retries "$COMMAND_RETRIES" rc-service startup-v2bx-watchdog restart
    return $?
  fi

  log_error "The V2bX watchdog needs systemd or OpenRC."
  return 1
}

v2bx_write_config() {
  local config_temp="$V2BX_CONFIG_DIR/config.json.$$"
  local sing_temp="$V2BX_CONFIG_DIR/sing_origin.json.$$"
  local config_backup="$V2BX_CONFIG_DIR/config.json.backup.$$"
  local sing_backup="$V2BX_CONFIG_DIR/sing_origin.json.backup.$$"

  [[ -r "$V2BX_CONFIG_TEMPLATE" && -r "$V2BX_SING_TEMPLATE" ]] || {
    log_error "V2bX example configuration files are missing."
    return 1
  }

  mkdir -p "$V2BX_CONFIG_DIR" || return 1
  umask 077
  if ! jq \
    --arg api_host "$ApiHost" \
    --rawfile api_key <(printf '%s' "$ApiKey") \
    --argjson anytls_id "$NodeID_anytls" \
    --argjson hysteria2_id "$NodeID_hysteria2" \
    '.Nodes[0].ApiHost = $api_host |
     .Nodes[1].ApiHost = $api_host |
     .Nodes[0].ApiKey = $api_key |
     .Nodes[1].ApiKey = $api_key |
     .Nodes[0].NodeID = $anytls_id |
     .Nodes[0].NodeType = "anytls" |
     .Nodes[1].NodeID = $hysteria2_id |
     .Nodes[1].NodeType = "hysteria2"' \
    "$V2BX_CONFIG_TEMPLATE" > "$config_temp"; then
    rm -f "$config_temp" "$sing_temp"
    return 1
  fi

  if ! cp "$V2BX_SING_TEMPLATE" "$sing_temp" || ! chmod 0600 "$config_temp" "$sing_temp"; then
    rm -f "$config_temp" "$sing_temp" "$config_backup" "$sing_backup"
    return 1
  fi

  [[ ! -f "$V2BX_CONFIG_PATH" ]] || cp -p "$V2BX_CONFIG_PATH" "$config_backup" || {
    rm -f "$config_temp" "$sing_temp"
    return 1
  }
  [[ ! -f "$V2BX_SING_PATH" ]] || cp -p "$V2BX_SING_PATH" "$sing_backup" || {
    rm -f "$config_temp" "$sing_temp" "$config_backup"
    return 1
  }

  if ! mv -f "$config_temp" "$V2BX_CONFIG_PATH"; then
    [[ ! -f "$config_backup" ]] || mv -f "$config_backup" "$V2BX_CONFIG_PATH"
    rm -f "$config_temp" "$sing_temp" "$sing_backup"
    return 1
  fi

  if ! mv -f "$sing_temp" "$V2BX_SING_PATH"; then
    [[ ! -f "$sing_backup" ]] || mv -f "$sing_backup" "$V2BX_SING_PATH"
    rm -f "$sing_temp"
    return 1
  fi

  rm -f "$config_backup" "$sing_backup"
}

step_check() {
  v2bx_variables_valid &&
    [[ -x "$V2BX_BINARY" ]] &&
    v2bx_config_matches &&
    v2bx_service_enabled &&
    v2bx_service_running &&
    v2bx_watchdog_scheduler_healthy
}

step_repair() {
  if ! v2bx_variables_valid; then
    log_error "ApiHost must be an HTTP(S) URL, ApiKey is required, and both Node IDs must be positive integers without leading zeroes."
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "V2bX config.json and sing_origin.json will be written to /etc/V2bX."
    log_info "A watchdog will check V2bX every minute and start it when it is down."
    run_cmd jq --arg api_host "$ApiHost" --arg api_key hidden \
      --argjson anytls_id "$NodeID_anytls" --argjson hysteria2_id "$NodeID_hysteria2" \
      . "$V2BX_CONFIG_TEMPLATE"
    return 0
  fi

  [[ -x "$V2BX_BINARY" ]] || {
    log_error "V2bX is not installed."
    return 1
  }

  if ! v2bx_config_matches && ! v2bx_write_config; then
    log_error "Could not generate the V2bX configuration."
    return 1
  fi

  v2bx_start_service &&
    v2bx_wait_running &&
    v2bx_watchdog_install_scheduler
}
