#!/usr/bin/env bash

STEP_ID="00"
STEP_NAME="Base environment"
STEP_DESCRIPTION="Keep the basic tools required by later setup steps installed."

BASE_PACKAGES=(ca-certificates coreutils curl wget tar gzip unzip grep)
BASE_COMMANDS=(cksum curl wget tar gzip unzip grep)

package_installed() {
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

step_check() {
  local item

  for item in "${BASE_PACKAGES[@]}"; do
    if ! package_installed "$item"; then
      return 1
    fi
  done

  for item in "${BASE_COMMANDS[@]}"; do
    if ! command_exists "$item"; then
      return 1
    fi
  done
}

repair_debian() {
  local apt_options=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold)

  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" "${apt_options[@]}" update
  if ! run_with_retries "$COMMAND_RETRIES" dpkg --force-confold --configure -a; then
    log_warn "Could not configure pending packages. Continuing with dependency repair."
  fi
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" "${apt_options[@]}" -f install -y
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" "${apt_options[@]}" install -y "${BASE_PACKAGES[@]}"
}

repair_rhel() {
  if ! run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" clean all; then
    log_warn "Could not clean the package cache. Continuing with package installation."
  fi
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" install -y "${BASE_PACKAGES[@]}"
}

repair_arch() {
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" -Syy --noconfirm
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" -S --needed --noconfirm "${BASE_PACKAGES[@]}"
}

repair_alpine() {
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" update
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" add --no-cache "${BASE_PACKAGES[@]}"
}

repair_suse() {
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" --non-interactive --gpg-auto-import-keys refresh
  run_with_retries "$COMMAND_RETRIES" "$SYSTEM_PACKAGE_MANAGER" --non-interactive --gpg-auto-import-keys --auto-agree-with-licenses install -y "${BASE_PACKAGES[@]}"
}

step_repair() {
  case "$SYSTEM_OS_FAMILY" in
    debian)
      repair_debian
      ;;
    rhel)
      repair_rhel
      ;;
    arch)
      repair_arch
      ;;
    alpine)
      repair_alpine
      ;;
    suse)
      repair_suse
      ;;
    *)
      log_error "Base environment does not support OS family '$SYSTEM_OS_FAMILY'."
      return 1
      ;;
  esac
}
