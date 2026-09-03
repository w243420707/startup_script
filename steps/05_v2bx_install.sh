#!/usr/bin/env bash

STEP_ID="05"
STEP_NAME="V2bX installation"
STEP_DESCRIPTION="Install V2bX and its service without generating user configuration."

V2BX_VERSION="0.4.0"
V2BX_INSTALL_DIR="/usr/local/V2bX"
V2BX_BINARY="$V2BX_INSTALL_DIR/V2bX"
V2BX_SYSTEMD_SERVICE="/etc/systemd/system/V2bX.service"
V2BX_OPENRC_SERVICE="/etc/init.d/V2bX"

v2bx_release_details() {
  case "$SYSTEM_ARCH" in
    amd64) V2BX_ASSET="V2bX-linux-64.zip"; V2BX_SHA256="ba694f3285a5653ce75db305b37407f553490dc524012890bacec8f0c2770253" ;;
    386) V2BX_ASSET="V2bX-linux-32.zip"; V2BX_SHA256="0e5ed97954fe754dc28d5bb0256641a91edbbed25cea3122017123ef11d0c746" ;;
    arm64) V2BX_ASSET="V2bX-linux-arm64-v8a.zip"; V2BX_SHA256="02402839a2d7a67f077a299a27250ba96ec25f27ad22826198b8392d30b50ca3" ;;
    armv7) V2BX_ASSET="V2bX-linux-arm32-v7a.zip"; V2BX_SHA256="a6aa0eb04161b78eba8455262e70cac23ec6f35d33e80ddbf798b216c684723d" ;;
    armv6) V2BX_ASSET="V2bX-linux-arm32-v6.zip"; V2BX_SHA256="96e660bf0bd0f3ee545d00a4370e1d399d46a84de7c4f1691e66a1c2d2aa6e82" ;;
    riscv64) V2BX_ASSET="V2bX-linux-riscv64.zip"; V2BX_SHA256="fe1a522de699bea867f89b3ff32355c953c457590057d06d98a55cfde993581e" ;;
    ppc64le) V2BX_ASSET="V2bX-linux-ppc64le.zip"; V2BX_SHA256="abbf47ce7e74a64796adb12953dcc2c7eb0ea9281d98d660cd57a71251a3ecfc" ;;
    s390x) V2BX_ASSET="V2bX-linux-s390x.zip"; V2BX_SHA256="16eec73605feb5be02800742c7d30aacf14c18c65c9cf7bca4255cf55f60198b" ;;
    *) return 1 ;;
  esac
}

v2bx_service_exists() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl cat V2bX.service >/dev/null 2>&1
    return $?
  fi
  [[ -x "$V2BX_OPENRC_SERVICE" ]]
}

v2bx_stop_and_disable() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl disable --now V2bX.service >/dev/null 2>&1 || true
  elif command_exists rc-service && [[ -x "$V2BX_OPENRC_SERVICE" ]]; then
    rc-service V2bX stop >/dev/null 2>&1 || true
    rc-update del V2bX default >/dev/null 2>&1 || true
  fi
}

v2bx_systemd_contents() {
  cat <<EOF
[Unit]
Description=V2bX Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
Type=simple
WorkingDirectory=$V2BX_INSTALL_DIR
ExecStart=$V2BX_BINARY server
Restart=always
RestartSec=10s
LimitNOFILE=999999

[Install]
WantedBy=multi-user.target
EOF
}

v2bx_openrc_contents() {
  cat <<EOF
#!/sbin/openrc-run
name="V2bX"
description="V2bX"
command="$V2BX_BINARY"
command_args="server"
command_user="root"
command_background="yes"
pidfile="/run/V2bX.pid"
depend() { need net; }
EOF
}

v2bx_install_service() {
  local path mode generator temp_path
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    path="$V2BX_SYSTEMD_SERVICE"
    mode=0644
    generator=v2bx_systemd_contents
  elif command_exists rc-update; then
    path="$V2BX_OPENRC_SERVICE"
    mode=0755
    generator=v2bx_openrc_contents
  else
    return 1
  fi
  temp_path="${path}.$$"
  "$generator" > "$temp_path" && chmod "$mode" "$temp_path" && mv -f "$temp_path" "$path" || return 1
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl daemon-reload
  fi
}

v2bx_install_release() {
  local archive="$STATE_DIR/$V2BX_ASSET"
  local stage="$STATE_DIR/v2bx-release.$$"
  local backup="${V2BX_INSTALL_DIR}.backup.$$"
  local url="https://github.com/wyx2685/V2bX/releases/download/v$V2BX_VERSION/$V2BX_ASSET"
  local geoip_temp="/etc/V2bX/geoip.dat.$$"
  local geosite_temp="/etc/V2bX/geosite.dat.$$"
  local geoip_backup="/etc/V2bX/geoip.dat.backup.$$"
  local geosite_backup="/etc/V2bX/geosite.dat.backup.$$"

  if [[ ! -s "$archive" ]] ||
     ! printf '%s  %s\n' "$V2BX_SHA256" "$archive" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$archive"
    run_with_retries "$COMMAND_RETRIES" curl -fL --connect-timeout 15 --max-time 300 "$url" -o "$archive" || return 1
  fi
  printf '%s  %s\n' "$V2BX_SHA256" "$archive" | sha256sum -c - >/dev/null 2>&1 || return 1

  rm -rf "$stage" "$backup"
  mkdir -p "$stage" || return 1
  unzip -oq "$archive" -d "$stage" || {
    rm -rf "$stage"
    return 1
  }
  [[ -s "$stage/V2bX" && -s "$stage/geoip.dat" && -s "$stage/geosite.dat" ]] || {
    rm -rf "$stage"
    return 1
  }
  chmod 0755 "$stage/V2bX"
  printf '%s\n' "$V2BX_VERSION" > "$stage/.startup-version"

  if ! mkdir -p /etc/V2bX ||
     ! cp "$stage/geoip.dat" "$geoip_temp" ||
     ! cp "$stage/geosite.dat" "$geosite_temp" ||
     ! chmod 0644 "$geoip_temp" "$geosite_temp"; then
    rm -rf "$stage"
    rm -f "$geoip_temp" "$geosite_temp"
    return 1
  fi
  if [[ -f /etc/V2bX/geoip.dat ]] && ! cp -p /etc/V2bX/geoip.dat "$geoip_backup"; then
    rm -rf "$stage"
    rm -f "$geoip_temp" "$geosite_temp"
    return 1
  fi
  if [[ -f /etc/V2bX/geosite.dat ]] && ! cp -p /etc/V2bX/geosite.dat "$geosite_backup"; then
    rm -rf "$stage"
    rm -f "$geoip_temp" "$geosite_temp" "$geoip_backup"
    return 1
  fi

  v2bx_stop_and_disable
  [[ ! -d "$V2BX_INSTALL_DIR" ]] || mv "$V2BX_INSTALL_DIR" "$backup" || return 1
  if ! mv "$stage" "$V2BX_INSTALL_DIR" ||
     ! v2bx_install_service ||
     ! mv -f "$geoip_temp" /etc/V2bX/geoip.dat ||
     ! mv -f "$geosite_temp" /etc/V2bX/geosite.dat; then
    rm -rf "$V2BX_INSTALL_DIR"
    [[ ! -d "$backup" ]] || mv "$backup" "$V2BX_INSTALL_DIR"
    if [[ -f "$geoip_backup" ]]; then
      mv -f "$geoip_backup" /etc/V2bX/geoip.dat
    else
      rm -f /etc/V2bX/geoip.dat
    fi
    if [[ -f "$geosite_backup" ]]; then
      mv -f "$geosite_backup" /etc/V2bX/geosite.dat
    else
      rm -f /etc/V2bX/geosite.dat
    fi
    rm -rf "$stage"
    rm -f "$geoip_temp" "$geosite_temp"
    return 1
  fi
  rm -rf "$backup"
  rm -f "$geoip_backup" "$geosite_backup"
}

step_check() {
  [[ -x "$V2BX_BINARY" && -s /etc/V2bX/geoip.dat && -s /etc/V2bX/geosite.dat ]] &&
    grep -qx "$V2BX_VERSION" "$V2BX_INSTALL_DIR/.startup-version" 2>/dev/null &&
    v2bx_service_exists
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "V2bX $V2BX_VERSION will be checksum-verified and installed without starting it."
    return 0
  fi
  v2bx_release_details || {
    log_error "V2bX does not support architecture $SYSTEM_ARCH."
    return 1
  }
  v2bx_install_release && v2bx_stop_and_disable && step_check
}
