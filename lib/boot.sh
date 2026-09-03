#!/usr/bin/env bash

BOOT_SERVICE_NAME="startup-script.service"
BOOT_SERVICE_PATH="/etc/systemd/system/$BOOT_SERVICE_NAME"
OPENRC_SERVICE_PATH="/etc/local.d/startup-script.start"

systemd_service_contents() {
  local shell_path="$1"
  local script_path="$2"
  local escaped_script_path

  printf -v escaped_script_path '%q' "$script_path"

  cat <<EOF
[Unit]
Description=VPS startup self-healing script
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=10min
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$shell_path $escaped_script_path install --yes
Environment=DEBIAN_FRONTEND=noninteractive
Environment=APT_LISTCHANGES_FRONTEND=none
Environment=NEEDRESTART_MODE=a
TimeoutStartSec=30min
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
EOF
}

openrc_service_contents() {
  local shell_path="$1"
  local script_path="$2"

  cat <<EOF
#!/bin/sh
exec $shell_path $(printf '%q' "$script_path") install --yes
EOF
}

ensure_systemd_service() {
  local shell_path temp_file

  shell_path="$(command -v bash)"
  temp_file="$STATE_DIR/$BOOT_SERVICE_NAME.$$"
  if ! mkdir -p "$(dirname -- "$BOOT_SERVICE_PATH")"; then
    log_warn "Could not create the systemd service directory."
    return 1
  fi
  if ! systemd_service_contents "$shell_path" "$SCRIPT_DIR/startup.sh" > "$temp_file"; then
    rm -f "$temp_file"
    log_warn "Could not generate the systemd service file."
    return 1
  fi

  if ! chmod 0644 "$temp_file" || ! mv -f "$temp_file" "$BOOT_SERVICE_PATH"; then
    rm -f "$temp_file"
    log_warn "Could not install the systemd service file."
    return 1
  fi

  if ! run_with_retries "$COMMAND_RETRIES" systemctl daemon-reload; then
    log_warn "systemd daemon reload failed."
    return 1
  fi
  if ! run_with_retries "$COMMAND_RETRIES" systemctl enable "$BOOT_SERVICE_NAME"; then
    log_warn "systemd service enable failed."
    return 1
  fi
  log_success "Boot self-healing service is enabled with systemd."
}

ensure_openrc_service() {
  local shell_path temp_file

  shell_path="$(command -v bash)"
  temp_file="$STATE_DIR/startup-script.start.$$"
  if ! mkdir -p "$(dirname -- "$OPENRC_SERVICE_PATH")" || ! openrc_service_contents "$shell_path" "$SCRIPT_DIR/startup.sh" > "$temp_file"; then
    rm -f "$temp_file"
    log_warn "Could not generate the OpenRC startup script."
    return 1
  fi

  if ! chmod 0755 "$temp_file" || ! mv -f "$temp_file" "$OPENRC_SERVICE_PATH"; then
    rm -f "$temp_file"
    log_warn "Could not install the OpenRC startup script."
    return 1
  fi

  if ! run_with_retries "$COMMAND_RETRIES" rc-update add local default; then
    log_warn "OpenRC local service registration failed."
    return 1
  fi
  log_success "Boot self-healing service is enabled with OpenRC."
}

ensure_boot_service() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "Dry-run mode: boot service would be enabled when systemd or OpenRC is available."
    return 0
  fi

  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    ensure_systemd_service
    return $?
  fi

  if command_exists rc-update; then
    ensure_openrc_service
    return $?
  fi

  log_warn "Neither systemd nor OpenRC is available. Boot service registration skipped."
  return 1
}
