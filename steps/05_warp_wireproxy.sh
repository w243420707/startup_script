#!/usr/bin/env bash

STEP_ID="05"
STEP_NAME="WARP WireProxy"
STEP_DESCRIPTION="Install WARP WireProxy through fscarmen menu.sh w on local SOCKS5 port 40000."

FSCARMEN_WARP_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
FSCARMEN_WARP_DIR="$STATE_DIR/fscarmen-warp"
FSCARMEN_WARP_MANAGER="/etc/wireguard/menu.sh"
WIREPROXY_BINARY="/usr/bin/wireproxy"
WIREPROXY_CONFIG="/etc/wireguard/proxy.conf"
WIREPROXY_PORT="40000"
WIREPROXY_PROVIDER="fscarmen-menu-w"
WIREPROXY_PROVIDER_STATE="$STATE_DIR/wireproxy.provider"

wireproxy_service_exists() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl cat wireproxy.service >/dev/null 2>&1
    return $?
  fi
  [[ -x /etc/init.d/wireproxy ]]
}

wireproxy_service_enabled() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-enabled --quiet wireproxy.service
    return $?
  fi
  command_exists rc-update && rc-update show 2>/dev/null | grep -Eq '^[[:space:]]*wireproxy[[:space:]]'
}

wireproxy_service_running() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-active --quiet wireproxy.service
    return $?
  fi
  command_exists rc-service && rc-service wireproxy status >/dev/null 2>&1
}

wireproxy_config_valid() {
  [[ -r "$WIREPROXY_CONFIG" ]] &&
    grep -Eq "^[[:space:]]*BindAddress[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:${WIREPROXY_PORT}[[:space:]]*$" "$WIREPROXY_CONFIG"
}

wireproxy_listening() {
  ss -lnt 2>/dev/null | grep -Eq "127\\.0\\.0\\.1:${WIREPROXY_PORT}[[:space:]]"
}

wireproxy_works() {
  local trace
  trace="$(curl -fsS --connect-timeout 8 --max-time 15 \
    --proxy "socks5h://127.0.0.1:$WIREPROXY_PORT" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" || return 1
  grep -Eq '^warp=(on|plus)$' <<< "$trace"
}

wireproxy_provider_valid() {
  [[ -x "$FSCARMEN_WARP_MANAGER" ]] &&
    grep -qx "$WIREPROXY_PROVIDER" "$WIREPROXY_PROVIDER_STATE" 2>/dev/null
}

wireproxy_stop_existing() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl stop wireproxy.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/wireproxy.service
    systemctl daemon-reload
  elif command_exists rc-service; then
    rc-service wireproxy stop >/dev/null 2>&1 || true
  fi
}

wireproxy_restart() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    run_with_retries "$COMMAND_RETRIES" systemctl restart wireproxy.service
    return $?
  fi
  run_with_retries "$COMMAND_RETRIES" rc-service wireproxy restart
}

wireproxy_wait_local() {
  local attempt
  for ((attempt = 1; attempt <= 15; attempt++)); do
    wireproxy_service_running && wireproxy_listening && return 0
    sleep 2
  done
  return 1
}

wireproxy_install_with_fscarmen() {
  local status

  mkdir -p "$FSCARMEN_WARP_DIR" /etc/wireguard || return 1
  [[ -s /etc/wireguard/language ]] || printf 'E\n' > /etc/wireguard/language
  wireproxy_stop_existing || return 1

  log_info "Downloading and running fscarmen menu.sh w."
  (
    cd "$FSCARMEN_WARP_DIR" || exit 1
    run_with_retries "$COMMAND_RETRIES" wget -4 -N "$FSCARMEN_WARP_URL" || exit 1
    printf '1\n\n' | bash menu.sh w
  )
  status=$?
  [[ "$status" -eq 0 ]] || return "$status"

  wireproxy_wait_local && wireproxy_works || return 1
  printf '%s\n' "$WIREPROXY_PROVIDER" > "$WIREPROXY_PROVIDER_STATE"
}

step_check() {
  [[ -x "$WIREPROXY_BINARY" ]] &&
    wireproxy_provider_valid &&
    wireproxy_service_exists &&
    wireproxy_service_enabled &&
    wireproxy_service_running &&
    wireproxy_config_valid &&
    wireproxy_listening &&
    wireproxy_works
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "The original fscarmen menu.sh w installer will configure WireProxy on 127.0.0.1:40000."
    return 0
  fi

  if wireproxy_provider_valid && wireproxy_service_exists && wireproxy_config_valid; then
    wireproxy_restart && wireproxy_wait_local && wireproxy_works
    return $?
  fi

  wireproxy_install_with_fscarmen
}
