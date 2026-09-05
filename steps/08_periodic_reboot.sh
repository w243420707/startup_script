#!/usr/bin/env bash

STEP_ID="08"
STEP_NAME="Remove unsafe VPS reboot"
STEP_DESCRIPTION="Remove legacy tasks that rebooted the VPS every 3 hours; WireProxy is restarted separately to control memory use."

PERIODIC_REBOOT_SYSTEMD_SERVICE="/etc/systemd/system/startup-periodic-reboot.service"
PERIODIC_REBOOT_SYSTEMD_TIMER="/etc/systemd/system/startup-periodic-reboot.timer"
PERIODIC_REBOOT_OPENRC_SERVICE="/etc/init.d/startup-periodic-reboot"

periodic_reboot_cleanup() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl disable --now startup-periodic-reboot.timer >/dev/null 2>&1 || true
    rm -f "$PERIODIC_REBOOT_SYSTEMD_SERVICE" "$PERIODIC_REBOOT_SYSTEMD_TIMER"
    run_with_retries "$COMMAND_RETRIES" systemctl daemon-reload
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    rc-service startup-periodic-reboot stop >/dev/null 2>&1 || true
    rc-update del startup-periodic-reboot default >/dev/null 2>&1 || true
    rm -f "$PERIODIC_REBOOT_OPENRC_SERVICE"
  fi
}

periodic_reboot_healthy() {
  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    ! systemctl is-enabled --quiet startup-periodic-reboot.timer 2>/dev/null &&
      ! systemctl is-active --quiet startup-periodic-reboot.timer 2>/dev/null &&
      [[ ! -e "$PERIODIC_REBOOT_SYSTEMD_SERVICE" ]] &&
      [[ ! -e "$PERIODIC_REBOOT_SYSTEMD_TIMER" ]]
    return $?
  fi

  if command_exists rc-service && command_exists rc-update; then
    [[ ! -e "$PERIODIC_REBOOT_OPENRC_SERVICE" ]] &&
      ! rc-update show 2>/dev/null | grep -Eq '^[[:space:]]*startup-periodic-reboot[[:space:]]'
    return $?
  fi

  return 0
}

step_check() {
  periodic_reboot_healthy
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "Any legacy VPS three-hour reboot task will be removed. The VPS will not be rebooted automatically."
    return 0
  fi

  periodic_reboot_cleanup
}
