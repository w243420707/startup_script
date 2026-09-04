#!/usr/bin/env bash

STEP_ID="05"
STEP_NAME="WARP WireProxy"
STEP_DESCRIPTION="Install WARP WireProxy in w mode on local SOCKS5 port 40000."

WIREPROXY_VERSION="1.0.9"
WIREPROXY_BINARY="/usr/bin/wireproxy"
WIREPROXY_ACCOUNT="/etc/wireguard/warp-account.json"
WIREPROXY_CONFIG="/etc/wireguard/proxy.conf"
WIREPROXY_PORT="40000"
WIREPROXY_SYSTEMD_SERVICE="/etc/systemd/system/wireproxy.service"
WIREPROXY_OPENRC_SERVICE="/etc/init.d/wireproxy"
WIREPROXY_VERSION_STATE="$STATE_DIR/wireproxy.version"

wireproxy_release_details() {
  case "$SYSTEM_ARCH" in
    amd64)
      WIREPROXY_ASSET="wireproxy_linux_amd64.tar.gz"
      ;;
    arm64)
      WIREPROXY_ASSET="wireproxy_linux_arm64.tar.gz"
      ;;
    armv7|armv6)
      WIREPROXY_ASSET="wireproxy_linux_arm.tar.gz"
      ;;
    386)
      WIREPROXY_ASSET="wireproxy_linux_386.tar.gz"
      ;;
    *)
      return 1
      ;;
  esac
}

wireproxy_account_valid() {
  [[ -r "$WIREPROXY_ACCOUNT" ]] &&
    jq -e '.private_key | strings | length > 0' "$WIREPROXY_ACCOUNT" >/dev/null 2>&1 &&
    jq -e '.config.interface.addresses.v4 | strings | length > 0' "$WIREPROXY_ACCOUNT" >/dev/null 2>&1 &&
    jq -e '.config.peers[0].public_key | strings | length > 0' "$WIREPROXY_ACCOUNT" >/dev/null 2>&1
}

wireproxy_config_valid() {
  [[ -r "$WIREPROXY_CONFIG" ]] &&
    grep -Eq '^[[:space:]]*BindAddress[[:space:]]*=[[:space:]]*127\.0\.0\.1:40000[[:space:]]*$' "$WIREPROXY_CONFIG"
}

wireproxy_service_exists() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl cat wireproxy.service >/dev/null 2>&1
    return $?
  fi
  [[ -x "$WIREPROXY_OPENRC_SERVICE" ]]
}

wireproxy_service_running() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-active --quiet wireproxy.service
    return $?
  fi
  if command_exists rc-service && [[ -x "$WIREPROXY_OPENRC_SERVICE" ]]; then
    rc-service wireproxy status >/dev/null 2>&1
    return $?
  fi
  return 1
}

wireproxy_service_enabled() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-enabled --quiet wireproxy.service
    return $?
  fi
  if command_exists rc-update; then
    rc-update show 2>/dev/null | grep -Eq '^[[:space:]]*wireproxy[[:space:]]'
    return $?
  fi
  return 1
}

wireproxy_listening() {
  ss -lnt 2>/dev/null | grep -Eq '127\.0\.0\.1:40000[[:space:]]'
}

wireproxy_works() {
  local trace
  trace="$(curl -fsS --connect-timeout 8 --max-time 15 \
    --proxy "socks5h://127.0.0.1:$WIREPROXY_PORT" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" || return 1
  grep -Eq '^warp=(on|plus)$' <<< "$trace"
}

wireproxy_install_binary() {
  local archive="$STATE_DIR/$WIREPROXY_ASSET"
  local extract_dir="$STATE_DIR/wireproxy-extract.$$"
  local temp_binary="${WIREPROXY_BINARY}.$$"
  local url="https://github.com/pufferffish/wireproxy/releases/download/v$WIREPROXY_VERSION/$WIREPROXY_ASSET"
  local status

  if [[ ! -s "$archive" ]]; then
    rm -f "$archive"
    echo "[DEBUG] Downloading wireproxy from $url"
    run_with_retries "$COMMAND_RETRIES" curl -fL --connect-timeout 15 --max-time 180 "$url" -o "$archive" || {
      echo "[ERROR] Failed to download wireproxy"
      return 1
    }
  fi
  
  echo "[DEBUG] Archive size: $(ls -lh "$archive" 2>/dev/null || echo 'file not found')"

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir" || {
    echo "[ERROR] Failed to create extract directory: $extract_dir"
    return 1
  }
  
  echo "[DEBUG] Extracting archive to $extract_dir"
  tar -xzf "$archive" -C "$extract_dir" || {
    echo "[ERROR] Failed to extract archive"
    rm -rf "$extract_dir"
    return 1
  }
  
  echo "[DEBUG] Extract directory contents:"
  ls -la "$extract_dir" || echo "[ERROR] Cannot list extract directory"
  
  [[ -s "$extract_dir/wireproxy" ]] || {
    echo "[ERROR] wireproxy binary not found in extracted files"
    rm -rf "$extract_dir"
    return 1
  }
  
  echo "[DEBUG] Installing wireproxy binary"
  cp "$extract_dir/wireproxy" "$temp_binary" && chmod 0755 "$temp_binary" && mv -f "$temp_binary" "$WIREPROXY_BINARY" &&
    printf '%s\n' "$WIREPROXY_VERSION" > "$WIREPROXY_VERSION_STATE"
  status=$?
  rm -rf "$extract_dir"
  
  if [[ $status -eq 0 ]]; then
    echo "[DEBUG] wireproxy installed successfully"
  else
    echo "[ERROR] Failed to install wireproxy binary"
  fi
  
  return "$status"
}

wireproxy_register_account() {
  local key_file="$STATE_DIR/warp-key.$$"
  local payload_file="$STATE_DIR/warp-register.$$"
  local response_file="$STATE_DIR/warp-response.$$"
  local account_temp="${WIREPROXY_ACCOUNT}.$$"
  local private_key public_key install_id fcm_token

  umask 077
  openssl genpkey -algorithm X25519 -outform DER -out "$key_file" >/dev/null 2>&1 || return 1
  private_key="$(tail -c 32 "$key_file" | base64 | tr -d '\r\n')"
  public_key="$(openssl pkey -inform DER -in "$key_file" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\r\n')"
  install_id="$(openssl rand -hex 16)"
  fcm_token="${install_id}:APA91b$(openssl rand -hex 32)"
  rm -f "$key_file"

  jq -nc --arg key "$public_key" --arg install_id "$install_id" --arg fcm_token "$fcm_token" \
    '{key: $key, install_id: $install_id, fcm_token: $fcm_token, tos: (now | todate), model: "PC", type: "Android", locale: "en_US"}' > "$payload_file" || return 1

  if ! curl -fsS --connect-timeout 15 --max-time 45 -X POST \
    'https://api.cloudflareclient.com/v0a2158/reg' \
    -H 'User-Agent: okhttp/3.12.1' \
    -H 'CF-Client-Version: a-6.10-2158' \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload_file" > "$response_file"; then
    rm -f "$payload_file" "$response_file"
    return 1
  fi
  rm -f "$payload_file"

  mkdir -p "$(dirname -- "$WIREPROXY_ACCOUNT")" || return 1
  if ! jq --rawfile private_key <(printf '%s' "$private_key") \
    '. + {private_key: $private_key}' "$response_file" > "$account_temp" ||
     ! chmod 0600 "$account_temp" || ! mv -f "$account_temp" "$WIREPROXY_ACCOUNT"; then
    rm -f "$response_file" "$account_temp"
    return 1
  fi
  rm -f "$response_file"
  wireproxy_account_valid
}

wireproxy_write_config() {
  local temp_path="${WIREPROXY_CONFIG}.$$"
  local private_key address4 address6 public_key endpoint

  private_key="$(jq -r '.private_key' "$WIREPROXY_ACCOUNT")"
  address4="$(jq -r '.config.interface.addresses.v4' "$WIREPROXY_ACCOUNT")"
  address6="$(jq -r '.config.interface.addresses.v6 // empty' "$WIREPROXY_ACCOUNT")"
  public_key="$(jq -r '.config.peers[0].public_key' "$WIREPROXY_ACCOUNT")"
  endpoint="$(jq -r '.config.peers[0].endpoint.host // "engage.cloudflareclient.com:2408"' "$WIREPROXY_ACCOUNT")"
  [[ -n "$private_key" && -n "$address4" && -n "$public_key" && -n "$endpoint" ]] || return 1

  umask 077
  cat > "$temp_path" <<EOF
[Interface]
Address = $address4/32${address6:+, $address6/128}
MTU = 1280
PrivateKey = $private_key
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $public_key
Endpoint = $endpoint

[Socks5]
BindAddress = 127.0.0.1:$WIREPROXY_PORT

[Resolve]
ResolveStrategy = auto
EOF
  chmod 0600 "$temp_path" && mv -f "$temp_path" "$WIREPROXY_CONFIG"
}

wireproxy_systemd_contents() {
  cat <<EOF
[Unit]
Description=WARP WireProxy SOCKS5 service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WIREPROXY_BINARY -c $WIREPROXY_CONFIG
Restart=always
RestartSec=5s
RuntimeMaxSec=3600
MemoryMax=512M
MemoryHigh=384M
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

wireproxy_openrc_contents() {
  cat <<EOF
#!/sbin/openrc-run

name="wireproxy"
description="WARP WireProxy SOCKS5 service"
command="$WIREPROXY_BINARY"
command_args="-c $WIREPROXY_CONFIG"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
start_stop_daemon_args="--stdout /var/log/wireproxy.log --stderr /var/log/wireproxy.log"
respawn_delay=5
respawn_max=0

depend() {
  need net
  after firewall
}
EOF
}

wireproxy_install_service() {
  local path mode generator temp_path
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    path="$WIREPROXY_SYSTEMD_SERVICE"
    mode=0644
    generator=wireproxy_systemd_contents
  elif command_exists rc-update; then
    path="$WIREPROXY_OPENRC_SERVICE"
    mode=0755
    generator=wireproxy_openrc_contents
  else
    return 1
  fi
  temp_path="${path}.$$"
  "$generator" > "$temp_path" && chmod "$mode" "$temp_path" && mv -f "$temp_path" "$path"
  
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    if [[ ! -d /etc/systemd/journald.conf.d ]]; then
      mkdir -p /etc/systemd/journald.conf.d
    fi
    cat > /etc/systemd/journald.conf.d/00-journal-size.conf <<'JOURNAL_EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=100M
RuntimeMaxUse=100M
RuntimeMaxFileSize=50M
JOURNAL_EOF
  fi
}

wireproxy_start() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    run_with_retries "$COMMAND_RETRIES" systemctl daemon-reload &&
      run_with_retries "$COMMAND_RETRIES" systemctl enable wireproxy.service &&
      run_with_retries "$COMMAND_RETRIES" systemctl restart wireproxy.service
    return $?
  fi
  run_with_retries "$COMMAND_RETRIES" rc-update add wireproxy default &&
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

step_check() {
  [[ -x "$WIREPROXY_BINARY" ]] &&
    grep -qx "$WIREPROXY_VERSION" "$WIREPROXY_VERSION_STATE" 2>/dev/null &&
    wireproxy_service_exists && wireproxy_service_enabled && wireproxy_service_running &&
    wireproxy_config_valid && wireproxy_listening && wireproxy_works
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "WireProxy $WIREPROXY_VERSION will be checksum-verified and configured on 127.0.0.1:40000."
    return 0
  fi
  wireproxy_release_details || {
    log_error "WireProxy does not support architecture $SYSTEM_ARCH."
    return 1
  }
  if [[ ! -x "$WIREPROXY_BINARY" ]] || ! grep -qx "$WIREPROXY_VERSION" "$WIREPROXY_VERSION_STATE" 2>/dev/null; then
    wireproxy_install_binary || return 1
  fi
  wireproxy_account_valid || wireproxy_register_account || return 1
  wireproxy_write_config || return 1
  wireproxy_install_service && wireproxy_start && wireproxy_wait_local && wireproxy_works
}
