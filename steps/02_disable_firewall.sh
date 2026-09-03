#!/usr/bin/env bash

STEP_ID="02"
STEP_NAME="Disable firewall"
STEP_DESCRIPTION="Stop and remove host firewall services, then allow all ports."

FIREWALL_SERVICES=(
  ufw
  firewalld
  nftables
  netfilter-persistent
  iptables
  ip6tables
  SuSEfirewall2_init
  SuSEfirewall2_setup
)

FIREWALL_CONFIG_PATHS=(
  /etc/default/ufw
  /etc/ufw
  /var/lib/ufw
  /etc/firewalld
  /etc/nftables.conf
  /etc/nftables
  /etc/iptables
  /etc/sysconfig/iptables
  /etc/sysconfig/ip6tables
  /etc/sysconfig/SuSEfirewall2
)

firewall_packages() {
  case "$SYSTEM_OS_FAMILY" in
    debian)
      printf '%s\n' ufw firewalld iptables-persistent netfilter-persistent
      ;;
    rhel)
      printf '%s\n' firewalld iptables-services
      ;;
    arch|alpine)
      printf '%s\n' ufw firewalld
      ;;
    suse)
      printf '%s\n' firewalld SuSEfirewall2
      ;;
  esac
}

firewall_package_installed() {
  local package="$1"
  local package_status

  case "$SYSTEM_OS_FAMILY" in
    debian)
      package_status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
      [[ "$package_status" == "install ok installed" ]]
      ;;
    rhel|suse)
      rpm -q "$package" >/dev/null 2>&1
      ;;
    arch)
      pacman -Q "$package" >/dev/null 2>&1
      ;;
    alpine)
      apk info -e "$package" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

firewall_service_active() {
  local service_name="$1"

  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-active --quiet "${service_name}.service"
  elif command_exists rc-service && [[ -x "/etc/init.d/$service_name" ]]; then
    rc-service "$service_name" status >/dev/null 2>&1
  elif command_exists service && [[ -x "/etc/init.d/$service_name" ]]; then
    service "$service_name" status >/dev/null 2>&1
  else
    return 1
  fi
}

firewall_service_enabled() {
  local service_name="$1"

  if [[ -d /run/systemd/system ]] && command_exists systemctl; then
    systemctl is-enabled --quiet "${service_name}.service" 2>/dev/null
  elif command_exists rc-update; then
    rc-update show 2>/dev/null | grep -Eq "^[[:space:]]*${service_name}[[:space:]]"
  elif command_exists chkconfig && [[ -x "/etc/init.d/$service_name" ]]; then
    chkconfig --list "$service_name" 2>/dev/null | grep -Eq '[[:space:]]on([[:space:]]|$)'
  else
    return 1
  fi
}

firewall_nft_open() {
  local ruleset

  command_exists nft || return 0
  if ! ruleset="$(nft list ruleset 2>/dev/null)"; then
    return 0
  fi

  ! grep -Eiq '(^|[[:space:]])(drop|reject)([[:space:];]|$)|policy[[:space:]]+(drop|reject)' <<< "$ruleset"
}

firewall_iptables_open() {
  local tool="$1"
  local rules chain

  command_exists "$tool" || return 0
  if ! rules="$($tool -S 2>/dev/null)"; then
    return 0
  fi

  for chain in INPUT FORWARD OUTPUT; do
    grep -qx -- "-P $chain ACCEPT" <<< "$rules" || return 1
  done

  ! grep -Eq -- '(^|[[:space:]])-j[[:space:]]+(DROP|REJECT)([[:space:]]|$)' <<< "$rules"
}

step_check() {
  local item

  for item in "${FIREWALL_SERVICES[@]}"; do
    if firewall_service_active "$item" || firewall_service_enabled "$item"; then
      return 1
    fi
  done

  while IFS= read -r item; do
    if [[ -n "$item" ]] && firewall_package_installed "$item"; then
      return 1
    fi
  done < <(firewall_packages)

  for item in "${FIREWALL_CONFIG_PATHS[@]}"; do
    [[ ! -e "$item" ]] || return 1
  done

  firewall_nft_open &&
    firewall_iptables_open iptables &&
    firewall_iptables_open ip6tables
}

open_iptables_rules() {
  local tool="$1"
  local chain status=0

  command_exists "$tool" || return 0

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    for chain in INPUT FORWARD OUTPUT; do
      run_cmd "$tool" -P "$chain" ACCEPT
    done
    run_cmd "$tool" -F
    run_cmd "$tool" -X
    return 0
  fi

  if ! "$tool" -S >/dev/null 2>&1; then
    log_warn "$tool is not available in this VPS environment. Skipping it."
    return 0
  fi

  for chain in INPUT FORWARD OUTPUT; do
    run_with_retries "$COMMAND_RETRIES" "$tool" -P "$chain" ACCEPT || status=1
  done
  run_with_retries "$COMMAND_RETRIES" "$tool" -F || status=1
  run_with_retries "$COMMAND_RETRIES" "$tool" -X || status=1
  return "$status"
}

open_all_ports() {
  local status=0

  if command_exists nft; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      run_cmd nft flush ruleset
    elif nft list ruleset >/dev/null 2>&1; then
      run_with_retries "$COMMAND_RETRIES" nft flush ruleset || status=1
    else
      log_warn "nft is not available in this VPS environment. Skipping it."
    fi
  fi

  open_iptables_rules iptables || status=1
  open_iptables_rules ip6tables || status=1
  return "$status"
}

disable_firewall_services() {
  local service_name unit_name status=0

  if command_exists ufw; then
    run_with_retries "$COMMAND_RETRIES" ufw --force disable || status=1
  fi

  for service_name in "${FIREWALL_SERVICES[@]}"; do
    unit_name="${service_name}.service"

    if [[ -d /run/systemd/system ]] && command_exists systemctl &&
       systemctl cat "$unit_name" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$unit_name"; then
        run_with_retries "$COMMAND_RETRIES" systemctl stop "$unit_name" || status=1
      fi
      if systemctl is-enabled --quiet "$unit_name" 2>/dev/null; then
        run_with_retries "$COMMAND_RETRIES" systemctl disable "$unit_name" || status=1
      fi
      continue
    fi

    if command_exists rc-service && [[ -x "/etc/init.d/$service_name" ]]; then
      if rc-service "$service_name" status >/dev/null 2>&1; then
        run_with_retries "$COMMAND_RETRIES" rc-service "$service_name" stop || status=1
      fi
      if command_exists rc-update &&
         rc-update show 2>/dev/null | grep -Eq "^[[:space:]]*${service_name}[[:space:]]"; then
        run_with_retries "$COMMAND_RETRIES" rc-update del "$service_name" || status=1
      fi
      continue
    fi

    if command_exists service && [[ -x "/etc/init.d/$service_name" ]] &&
       service "$service_name" status >/dev/null 2>&1; then
      run_with_retries "$COMMAND_RETRIES" service "$service_name" stop || status=1
    fi

    if command_exists update-rc.d && [[ -x "/etc/init.d/$service_name" ]]; then
      run_with_retries "$COMMAND_RETRIES" update-rc.d -f "$service_name" remove || status=1
    elif command_exists chkconfig && [[ -x "/etc/init.d/$service_name" ]]; then
      run_with_retries "$COMMAND_RETRIES" chkconfig "$service_name" off || status=1
    fi
  done

  return "$status"
}

remove_firewall_packages() {
  local package
  local -a installed_packages=()

  while IFS= read -r package; do
    if [[ -n "$package" ]] && firewall_package_installed "$package"; then
      installed_packages+=("$package")
    fi
  done < <(firewall_packages)

  [[ "${#installed_packages[@]}" -gt 0 ]] || return 0

  case "$SYSTEM_OS_FAMILY" in
    debian)
      run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" \
        -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confold \
        purge -y "${installed_packages[@]}"
      ;;
    rhel)
      run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" remove -y "${installed_packages[@]}"
      ;;
    arch)
      run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" -R --noconfirm "${installed_packages[@]}"
      ;;
    alpine)
      run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" del "${installed_packages[@]}"
      ;;
    suse)
      run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" --non-interactive remove -y "${installed_packages[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

remove_firewall_configs() {
  local config_path status=0

  for config_path in "${FIREWALL_CONFIG_PATHS[@]}"; do
    if [[ -e "$config_path" ]]; then
      run_with_retries "$COMMAND_RETRIES" rm -rf "$config_path" || status=1
    fi
  done

  return "$status"
}

step_repair() {
  local status=0

  open_all_ports || status=1
  disable_firewall_services || status=1
  open_all_ports || status=1
  remove_firewall_packages || status=1
  remove_firewall_configs || status=1
  hash -r
  open_all_ports || status=1
  return "$status"
}
