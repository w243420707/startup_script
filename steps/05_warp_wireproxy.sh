#!/usr/bin/env bash

STEP_ID="05"
STEP_NAME="WARP WireProxy"
STEP_DESCRIPTION="Install WARP WireProxy on local SOCKS5 port 40000 and restart it when the VPS public IPv4 changes."

FSCARMEN_WARP_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
FSCARMEN_WARP_DIR="$STATE_DIR/fscarmen-warp"
FSCARMEN_WARP_MANAGER="/etc/wireguard/menu.sh"
WIREPROXY_BINARY="/usr/bin/wireproxy"
WIREPROXY_CONFIG="/etc/wireguard/proxy.conf"
WIREPROXY_PORT="40000"
WIREPROXY_PROVIDER="fscarmen-menu-w"
WIREPROXY_PROVIDER_STATE="$STATE_DIR/wireproxy.provider"
WIREPROXY_IP_STATE="$STATE_DIR/wireproxy.public-ip"
WIREPROXY_IP_SYSTEMD_SERVICE="/etc/systemd/system/startup-wireproxy-ip.service"
WIREPROXY_IP_SYSTEMD_TIMER="/etc/systemd/system/startup-wireproxy-ip.timer"
WIREPROXY_IP_OPENRC_SERVICE="/etc/init.d/startup-wireproxy-ip"
WIREPROXY_IP_INTERVAL_SECONDS="120"

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

wireproxy_apply_memory_leak_fix() {
  # WireProxy 存在内存泄漏问题，每2小时自动重启一次
  # 修改 systemd 服务文件，添加 RuntimeMaxSec 参数
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    local service_file="/etc/systemd/system/wireproxy.service"
    
    if [[ ! -f "$service_file" ]]; then
      log_warn "wireproxy.service not found, skipping memory leak fix."
      return 0
    fi
    
    # 检查是否已经添加了 RuntimeMaxSec
    if grep -q '^RuntimeMaxSec=' "$service_file"; then
      log_info "WireProxy memory leak fix already applied."
      return 0
    fi
    
    log_info "Applying WireProxy memory leak fix (auto-restart every 2 hours)."
    
    # 在 [Service] 段落添加 RuntimeMaxSec 和 Restart 配置
    sed -i '/^\[Service\]/a RuntimeMaxSec=7200\nRestart=always\nRestartSec=5' "$service_file" || return 1
    
    # 重新加载 systemd 配置并重启服务
    systemctl daemon-reload || return 1
    systemctl restart wireproxy.service || return 1
    
    log_info "WireProxy will auto-restart every 2 hours to prevent memory leak."
    return 0
  fi
  
  # OpenRC 系统暂不支持自动重启，仅记录警告
  log_warn "OpenRC detected. Automatic WireProxy restart for memory leak fix is not implemented."
  return 0
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
  
  # 修复内存泄漏：添加定时重启配置
  wireproxy_apply_memory_leak_fix || return 1
  
  printf '%s\n' "$WIREPROXY_PROVIDER" > "$WIREPROXY_PROVIDER_STATE"
}

wireproxy_public_ipv4() {
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

wireproxy_ip_check() {
  local current_ip previous_ip temp_path

  current_ip="$(wireproxy_public_ipv4)" || {
    log_warn "Could not determine the VPS public IPv4. WireProxy was not restarted."
    return 1
  }

  if [[ ! -r "$WIREPROXY_IP_STATE" ]]; then
    umask 077
    printf '%s\n' "$current_ip" > "$WIREPROXY_IP_STATE"
    log_info "Recorded the initial VPS public IPv4: $current_ip."
    return 0
  fi

  read -r previous_ip < "$WIREPROXY_IP_STATE" || previous_ip=""
  if [[ "$previous_ip" == "$current_ip" ]]; then
    return 0
  fi

  log_warn "VPS public IPv4 changed from ${previous_ip:-unknown} to $current_ip. Restarting WireProxy."
  wireproxy_restart && wireproxy_wait_local && wireproxy_works || {
    log_error "WireProxy did not recover after the public IPv4 change."
    return 1
  }

  temp_path="${WIREPROXY_IP_STATE}.$$"
  umask 077
  printf '%s\n' "$current_ip" > "$temp_path" &&
    chmod 0600 "$temp_path" &&
    mv -f "$temp_path" "$WIREPROXY_IP_STATE"
}

wireproxy_ip_loop() {
  while true; do
    "$SCRIPT_DIR/startup.sh" wireproxy-ip-check || true
    sleep "$WIREPROXY_IP_INTERVAL_SECONDS"
  done
}

wireproxy_ip_systemd_service_contents() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  cat <<EOF
[Unit]
Description=Restart WireProxy when VPS public IPv4 changes
Wants=network-online.target
After=network-online.target wireproxy.service

[Service]
Type=oneshot
ExecStart=$bash_path $script_path wireproxy-ip-check
EOF
}

wireproxy_ip_systemd_timer_contents() {
  cat <<EOF
[Unit]
Description=Monitor the VPS public IPv4 for WireProxy

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

wireproxy_ip_openrc_service_contents() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  cat <<EOF
#!/sbin/openrc-run

name="startup-wireproxy-ip"
description="Restart WireProxy when the VPS public IPv4 changes"
command="$bash_path"
command_args="$script_path wireproxy-ip-loop"
command_background="yes"
pidfile="/run/startup-wireproxy-ip.pid"
depend() { need net; after wireproxy; }
EOF
}

wireproxy_ip_install_generated_file() {
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

wireproxy_ip_systemd_service_matches() {
  local bash_path script_path
  bash_path="$(command -v bash)"
  script_path="$SCRIPT_DIR/startup.sh"
  [[ -r "$WIREPROXY_IP_SYSTEMD_SERVICE" ]] &&
    grep -Fqx "Description=Restart WireProxy when VPS public IPv4 changes" "$WIREPROXY_IP_SYSTEMD_SERVICE" &&
    grep -Fqx "ExecStart=$bash_path $script_path wireproxy-ip-check" "$WIREPROXY_IP_SYSTEMD_SERVICE" &&
    [[ -r "$WIREPROXY_IP_SYSTEMD_TIMER" ]] &&
    grep -Fqx 'OnUnitActiveSec=2min' "$WIREPROXY_IP_SYSTEMD_TIMER"
}

wireproxy_ip_scheduler_healthy() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    wireproxy_ip_systemd_service_matches &&
      systemctl is-enabled --quiet startup-wireproxy-ip.timer &&
      systemctl is-active --quiet startup-wireproxy-ip.timer
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    [[ -x "$WIREPROXY_IP_OPENRC_SERVICE" ]] &&
      rc-update show 2>/dev/null | grep -Eq '^[[:space:]]*startup-wireproxy-ip[[:space:]]' &&
      rc-service startup-wireproxy-ip status >/dev/null 2>&1
    return $?
  fi

  return 1
}

wireproxy_ip_install_scheduler() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    wireproxy_ip_install_generated_file "$WIREPROXY_IP_SYSTEMD_SERVICE" 0644 wireproxy_ip_systemd_service_contents &&
      wireproxy_ip_install_generated_file "$WIREPROXY_IP_SYSTEMD_TIMER" 0644 wireproxy_ip_systemd_timer_contents &&
      run_with_retries "$COMMAND_RETRIES" systemctl daemon-reload &&
      run_with_retries "$COMMAND_RETRIES" systemctl enable --now startup-wireproxy-ip.timer
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    wireproxy_ip_install_generated_file "$WIREPROXY_IP_OPENRC_SERVICE" 0755 wireproxy_ip_openrc_service_contents &&
      run_with_retries "$COMMAND_RETRIES" rc-update add startup-wireproxy-ip default &&
      run_with_retries "$COMMAND_RETRIES" rc-service startup-wireproxy-ip restart
    return $?
  fi

  log_error "WireProxy IP monitoring needs systemd or OpenRC for scheduled checks."
  return 1
}

step_check() {
  [[ -x "$WIREPROXY_BINARY" ]] &&
    wireproxy_provider_valid &&
    wireproxy_service_exists &&
    wireproxy_service_enabled &&
    wireproxy_service_running &&
    wireproxy_config_valid &&
    wireproxy_listening &&
    wireproxy_works &&
    wireproxy_ip_scheduler_healthy
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "The original fscarmen menu.sh w installer will configure WireProxy on 127.0.0.1:40000."
    log_info "A service will check the VPS public IPv4 every 2 minutes and restart WireProxy after a change."
    return 0
  fi

  if wireproxy_provider_valid && wireproxy_service_exists && wireproxy_config_valid; then
    wireproxy_restart && wireproxy_wait_local && wireproxy_works || return 1
    wireproxy_ip_install_scheduler
    return $?
  fi

  wireproxy_install_with_fscarmen && wireproxy_ip_install_scheduler
}
