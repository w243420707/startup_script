#!/usr/bin/env bash

STEP_ID="06"
STEP_NAME="V2bX configuration"
STEP_DESCRIPTION="Generate the V2bX node configuration and start its service."

V2BX_CONFIG_TEMPLATE="$SCRIPT_DIR/example/config.json"
V2BX_SING_TEMPLATE="$SCRIPT_DIR/example/sing_origin.json"
V2BX_CONFIG_DIR="/etc/V2bX"
V2BX_CONFIG_PATH="$V2BX_CONFIG_DIR/config.json"
V2BX_SING_PATH="$V2BX_CONFIG_DIR/sing_origin.json"

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

  [[ ! -f "$V2BX_CONFIG_PATH" ]] || cp -p "$V2BX_CONFIG_PATH" "$config_backup" || return 1
  [[ ! -f "$V2BX_SING_PATH" ]] || cp -p "$V2BX_SING_PATH" "$sing_backup" || return 1
  if ! mv -f "$sing_temp" "$V2BX_SING_PATH" || ! mv -f "$config_temp" "$V2BX_CONFIG_PATH"; then
    [[ ! -f "$config_backup" ]] || mv -f "$config_backup" "$V2BX_CONFIG_PATH"
    [[ ! -f "$sing_backup" ]] || mv -f "$sing_backup" "$V2BX_SING_PATH"
    rm -f "$config_temp" "$sing_temp"
    return 1
  fi
  rm -f "$config_backup" "$sing_backup"
}

step_check() {
  v2bx_variables_valid &&
    [[ -x /usr/local/V2bX/V2bX ]] &&
    v2bx_config_matches &&
    v2bx_service_enabled &&
    v2bx_service_running
}

step_repair() {
  if ! v2bx_variables_valid; then
    log_error "ApiHost must be an HTTP(S) URL, ApiKey is required, and both Node IDs must be positive integers without leading zeroes."
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "V2bX config.json and sing_origin.json will be written to /etc/V2bX."
    run_cmd jq --arg api_host "$ApiHost" --arg api_key hidden \
      --argjson anytls_id "$NodeID_anytls" --argjson hysteria2_id "$NodeID_hysteria2" \
      . "$V2BX_CONFIG_TEMPLATE"
    return 0
  fi

  [[ -x /usr/local/V2bX/V2bX ]] || {
    log_error "V2bX is not installed."
    return 1
  }

  if ! v2bx_config_matches && ! v2bx_write_config; then
    log_error "Could not generate the V2bX configuration."
    return 1
  fi

  v2bx_start_service && v2bx_wait_running
}
