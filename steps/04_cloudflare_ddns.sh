#!/usr/bin/env bash

STEP_ID="04"
STEP_NAME="Cloudflare DDNS"
STEP_DESCRIPTION="Keep the configured Cloudflare A record pointed at this VPS."

CFRECORD_TYPE="A"
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_SYSTEMD_SERVICE="/etc/systemd/system/startup-cloudflare-ddns.service"
CF_SYSTEMD_TIMER="/etc/systemd/system/startup-cloudflare-ddns.timer"
CF_OPENRC_SERVICE="/etc/init.d/startup-cloudflare-ddns"

cf_config_valid() {
  [[ -n "${CFKEY:-}" && -n "${CFUSER:-}" && -n "${CFRECORD_NAME:-}" ]] || return 1
  [[ "$CFRECORD_NAME" == *.* ]] || return 1
  [[ "$CFRECORD_NAME" != *[[:space:]/]* ]]
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local -a command=(
    curl -fsS --connect-timeout 15 --max-time 45 --retry 2
    --config /dev/fd/3
    -X "$method" "$CF_API_BASE$endpoint"
  )

  if [[ -n "$data" ]]; then
    command+=(--data "$data")
  fi

  "${command[@]}" 3< <(
    printf 'header = "X-Auth-Email: %s"\n' "$CFUSER"
    printf 'header = "X-Auth-Key: %s"\n' "$CFKEY"
    printf 'header = "Content-Type: application/json"\n'
  )
}

cf_public_ipv4() {
  local endpoint address
  local -a endpoints=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.co/ip"
  )

  for endpoint in "${endpoints[@]}"; do
    address="$(curl -4fsS --connect-timeout 8 --max-time 15 "$endpoint" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
       awk -F. '{for (i=1; i<=4; i++) if ($i > 255) exit 1}' <<< "$address"; then
      printf '%s\n' "$address"
      return 0
    fi
  done

  return 1
}

cf_find_zone() {
  local candidate="${CFRECORD_NAME%.}"
  local encoded response zone_id

  while [[ "$candidate" == *.* ]]; do
    encoded="$(jq -rn --arg value "$candidate" '$value | @uri')"
    response="$(cf_api GET "/zones?name=$encoded&status=active&per_page=1")" || return 1
    zone_id="$(jq -r 'if .success == true then .result[0].id // empty else empty end' <<< "$response")"
    if [[ -n "$zone_id" ]]; then
      printf '%s %s\n' "$zone_id" "$candidate"
      return 0
    fi
    candidate="${candidate#*.}"
  done

  return 1
}

cf_record_response() {
  local zone_id="$1"
  local encoded_name

  encoded_name="$(jq -rn --arg value "${CFRECORD_NAME%.}" '$value | @uri')"
  cf_api GET "/zones/$zone_id/dns_records?type=A&name=$encoded_name&per_page=100"
}

cf_ddns_healthy() {
  local address zone_id zone_name response

  cf_config_valid || return 1
  address="$(cf_public_ipv4)" || return 1
  read -r zone_id zone_name < <(cf_find_zone) || return 1
  [[ -n "$zone_id" && -n "$zone_name" ]] || return 1
  response="$(cf_record_response "$zone_id")" || return 1
  jq -e --arg address "$address" \
    '.success == true and (.result | length) > 0 and all(.result[]; .content == $address)' \
    >/dev/null 2>&1 <<< "$response"
}

cf_ddns_sync() {
  local address zone_id zone_name response record_id record_address body result
  local -a record_ids=()

  if ! cf_config_valid; then
    log_error "CFKEY, CFUSER and a full CFRECORD_NAME are required."
    return 1
  fi

  address="$(cf_public_ipv4)" || {
    log_error "Could not determine the public IPv4 address."
    return 1
  }

  if ! read -r zone_id zone_name < <(cf_find_zone) || [[ -z "$zone_id" || -z "$zone_name" ]]; then
    log_error "Could not automatically find the Cloudflare zone for $CFRECORD_NAME."
    return 1
  fi

  response="$(cf_record_response "$zone_id")" || {
    log_error "Could not query the Cloudflare DNS record."
    return 1
  }
  jq -e '.success == true' >/dev/null 2>&1 <<< "$response" || {
    log_error "Cloudflare rejected the DNS record query."
    return 1
  }
  mapfile -t record_ids < <(jq -r '.result[].id' <<< "$response")

  if (( ${#record_ids[@]} > 0 )) && jq -e --arg address "$address" \
    'all(.result[]; .content == $address)' >/dev/null 2>&1 <<< "$response"; then
    log_success "Cloudflare A record $CFRECORD_NAME already points to $address."
    return 0
  fi

  if (( ${#record_ids[@]} > 0 )); then
    body="$(jq -nc --arg content "$address" '{content: $content}')"
    for record_id in "${record_ids[@]}"; do
      record_address="$(jq -r --arg id "$record_id" '.result[] | select(.id == $id) | .content' <<< "$response")"
      [[ "$record_address" == "$address" ]] && continue
      result="$(cf_api PATCH "/zones/$zone_id/dns_records/$record_id" "$body")" || {
        log_error "Could not update the Cloudflare A record."
        return 1
      }
      jq -e '.success == true' >/dev/null 2>&1 <<< "$result" || {
        log_error "Cloudflare rejected the DDNS update."
        return 1
      }
    done
  else
    body="$(jq -nc --arg name "${CFRECORD_NAME%.}" --arg content "$address" \
      '{type: "A", name: $name, content: $content, ttl: 120, proxied: false}')"
    result="$(cf_api POST "/zones/$zone_id/dns_records" "$body")" || {
      log_error "Could not create the Cloudflare A record."
      return 1
    }
  fi

  if [[ -n "${result:-}" ]] && ! jq -e '.success == true' >/dev/null 2>&1 <<< "$result"; then
    log_error "Cloudflare rejected the DDNS update."
    return 1
  fi

  log_success "Cloudflare A record $CFRECORD_NAME now points to $address."
}

cf_systemd_service_contents() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  cat <<EOF
[Unit]
Description=Cloudflare DDNS update for startup-script
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$bash_path $script_path ddns
EOF
}

cf_systemd_timer_contents() {
  cat <<'EOF'
[Unit]
Description=Run startup-script Cloudflare DDNS updates

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

cf_openrc_service_contents() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  cat <<EOF
#!/sbin/openrc-run

name="startup-cloudflare-ddns"
description="Cloudflare DDNS update loop for startup-script"
command="$bash_path"
command_args="$script_path ddns-loop"
command_background="yes"
pidfile="/run/startup-ddns.pid"
depend() { need net; }
EOF
}

cf_install_generated_file() {
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

cf_systemd_service_matches() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  [[ -r "$CF_SYSTEMD_SERVICE" ]] &&
    grep -Fqx "Description=Cloudflare DDNS update for startup-script" "$CF_SYSTEMD_SERVICE" &&
    grep -Fqx "ExecStart=$bash_path $script_path ddns" "$CF_SYSTEMD_SERVICE" &&
    [[ -r "$CF_SYSTEMD_TIMER" ]] &&
    grep -Fqx 'OnUnitActiveSec=5min' "$CF_SYSTEMD_TIMER"
}

cf_scheduler_healthy() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    cf_systemd_service_matches &&
      systemctl is-enabled --quiet startup-cloudflare-ddns.timer &&
      systemctl is-active --quiet startup-cloudflare-ddns.timer
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    [[ -x "$CF_OPENRC_SERVICE" ]] &&
      rc-update show 2>/dev/null | grep -Eq '^[[:space:]]*startup-cloudflare-ddns[[:space:]]' &&
      rc-service startup-cloudflare-ddns status >/dev/null 2>&1
    return $?
  fi

  return 1
}

cf_install_scheduler() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    cf_install_generated_file "$CF_SYSTEMD_SERVICE" 0644 cf_systemd_service_contents &&
      cf_install_generated_file "$CF_SYSTEMD_TIMER" 0644 cf_systemd_timer_contents &&
      run_with_retries "$COMMAND_RETRIES" systemctl daemon-reload &&
      run_with_retries "$COMMAND_RETRIES" systemctl enable --now startup-cloudflare-ddns.timer
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    cf_install_generated_file "$CF_OPENRC_SERVICE" 0755 cf_openrc_service_contents &&
      run_with_retries "$COMMAND_RETRIES" rc-update add startup-cloudflare-ddns default &&
      run_with_retries "$COMMAND_RETRIES" rc-service startup-cloudflare-ddns restart
    return $?
  fi

  log_error "Cloudflare DDNS needs systemd or OpenRC for scheduled updates."
  return 1
}

step_check() {
  cf_scheduler_healthy && cf_ddns_healthy
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "Cloudflare Zone will be detected automatically and the A record will be updated."
    run_cmd "$SCRIPT_DIR/startup.sh" ddns
    return 0
  fi

  cf_ddns_sync && cf_install_scheduler
}
