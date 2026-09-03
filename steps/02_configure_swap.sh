#!/usr/bin/env bash

STEP_ID="02"
STEP_NAME="Configure Swap"
STEP_DESCRIPTION="Create and configure 4GB swap file with swappiness=10."

SWAP_FILE="/swapfile"
SWAP_SIZE_MB=4096
SWAP_SWAPPINESS=10

swap_configured() {
  [[ -f "$SWAP_FILE" ]] || return 1
  swapon --show=NAME --noheadings | grep -Fqx "$SWAP_FILE" || return 1
  grep -Fqx "$SWAP_FILE none swap sw 0 0" /etc/fstab || return 1
  local current_swappiness
  current_swappiness="$(sysctl -n vm.swappiness 2>/dev/null)" || return 1
  [[ "$current_swappiness" == "$SWAP_SWAPPINESS" ]] || return 1
  grep -Eq "^vm\.swappiness=${SWAP_SWAPPINESS}$" /etc/sysctl.conf
}

configure_swap() {
  log_info "Disabling existing swap..."
  swapoff -a || true
  
  if [[ -f "$SWAP_FILE" ]]; then
    log_info "Removing old swap file..."
    rm -f "$SWAP_FILE" || {
      log_error "Failed to remove old swap file."
      return 1
    }
  fi
  
  log_info "Creating ${SWAP_SIZE_MB}MB swap file..."
  dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=none || {
    log_error "Failed to create swap file."
    rm -f "$SWAP_FILE"
    return 1
  }
  
  chmod 600 "$SWAP_FILE" || {
    log_error "Failed to set swap file permissions."
    rm -f "$SWAP_FILE"
    return 1
  }
  
  log_info "Initializing swap file..."
  mkswap "$SWAP_FILE" >/dev/null 2>&1 || {
    log_error "Failed to initialize swap file."
    rm -f "$SWAP_FILE"
    return 1
  }
  
  log_info "Enabling swap file..."
  swapon "$SWAP_FILE" || {
    log_error "Failed to enable swap file."
    return 1
  }
  
  log_info "Updating /etc/fstab..."
  sed -i '/\/swapfile/d' /etc/fstab || true
  printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab || {
    log_error "Failed to update /etc/fstab."
    return 1
  }
  
  log_info "Setting vm.swappiness to ${SWAP_SWAPPINESS}..."
  sysctl vm.swappiness="$SWAP_SWAPPINESS" >/dev/null 2>&1 || {
    log_error "Failed to set vm.swappiness."
    return 1
  }
  
  sed -i '/vm.swappiness/d' /etc/sysctl.conf || true
  printf 'vm.swappiness=%d\n' "$SWAP_SWAPPINESS" >> /etc/sysctl.conf || {
    log_error "Failed to persist vm.swappiness."
    return 1
  }
  
  log_success "Swap configured: ${SWAP_SIZE_MB}MB, swappiness=${SWAP_SWAPPINESS}."
}

step_check() {
  swap_configured
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "Would create ${SWAP_SIZE_MB}MB swap file with swappiness=${SWAP_SWAPPINESS}."
    return 0
  fi
  
  configure_swap
}
