#!/usr/bin/env bash

detect_system() {
  local os_release_file="/etc/os-release"
  SYSTEM_OS_ID="unknown"
  SYSTEM_OS_NAME="Unknown Linux"
  SYSTEM_OS_VERSION="unknown"
  SYSTEM_OS_FAMILY="unknown"
  SYSTEM_PACKAGE_MANAGER="unknown"
  SYSTEM_ARCH_RAW="unknown"
  SYSTEM_ARCH="unknown"
  SYSTEM_OS_LIKE=""

  if [[ -r "$os_release_file" ]]; then
    SYSTEM_OS_ID="$(. "$os_release_file"; printf '%s' "${ID:-unknown}")"
    SYSTEM_OS_NAME="$(. "$os_release_file"; printf '%s' "${PRETTY_NAME:-${NAME:-Unknown Linux}}")"
    SYSTEM_OS_VERSION="$(. "$os_release_file"; printf '%s' "${VERSION_ID:-unknown}")"
    SYSTEM_OS_LIKE="$(. "$os_release_file"; printf '%s' "${ID_LIKE:-}")"
  fi

  case "$SYSTEM_OS_ID:$SYSTEM_OS_LIKE" in
    debian:*|ubuntu:*|linuxmint:*|kali:*|deepin:*|raspbian:*|*:debian*|*:ubuntu*)
      SYSTEM_OS_FAMILY="debian"
      SYSTEM_PACKAGE_MANAGER="apt-get"
      ;;
    rhel:*|centos:*|rocky:*|almalinux:*|fedora:*|ol:*|amzn:*|*:rhel*|*:fedora*)
      SYSTEM_OS_FAMILY="rhel"
      if command_exists dnf; then
        SYSTEM_PACKAGE_MANAGER="dnf"
      else
        SYSTEM_PACKAGE_MANAGER="yum"
      fi
      ;;
    arch:*|manjaro:*|endeavouros:*|*:arch*)
      SYSTEM_OS_FAMILY="arch"
      SYSTEM_PACKAGE_MANAGER="pacman"
      ;;
    alpine:*|*:alpine*)
      SYSTEM_OS_FAMILY="alpine"
      SYSTEM_PACKAGE_MANAGER="apk"
      ;;
    opensuse:*|opensuse-leap:*|opensuse-tumbleweed:*|sles:*|sled:*|*:suse*)
      SYSTEM_OS_FAMILY="suse"
      SYSTEM_PACKAGE_MANAGER="zypper"
      ;;
    *)
      SYSTEM_PACKAGE_MANAGER="unknown"
      ;;
  esac

  SYSTEM_ARCH_RAW="$(uname -m)"
  case "$SYSTEM_ARCH_RAW" in
    x86_64|amd64)
      SYSTEM_ARCH="amd64"
      ;;
    aarch64|arm64)
      SYSTEM_ARCH="arm64"
      ;;
    armv7l|armv7|armhf)
      SYSTEM_ARCH="armv7"
      ;;
    armv6l|armv6)
      SYSTEM_ARCH="armv6"
      ;;
    i386|i686|x86)
      SYSTEM_ARCH="386"
      ;;
    riscv64)
      SYSTEM_ARCH="riscv64"
      ;;
    ppc64le)
      SYSTEM_ARCH="ppc64le"
      ;;
    s390x)
      SYSTEM_ARCH="s390x"
      ;;
    *)
      SYSTEM_ARCH="$SYSTEM_ARCH_RAW"
      ;;
  esac

  if [[ "$SYSTEM_PACKAGE_MANAGER" != "unknown" ]] && ! command_exists "$SYSTEM_PACKAGE_MANAGER"; then
    log_warn "Detected package manager '$SYSTEM_PACKAGE_MANAGER' is not available."
    SYSTEM_PACKAGE_MANAGER="unknown"
  fi
}

print_system_info() {
  printf '\n'
  printf '%s\n' "System information"
  printf '%s\n' "------------------"
  printf 'OS           : %s\n' "$SYSTEM_OS_NAME"
  printf 'OS family    : %s\n' "$SYSTEM_OS_FAMILY"
  printf 'Architecture : %s (raw: %s)\n' "$SYSTEM_ARCH" "$SYSTEM_ARCH_RAW"
  printf 'Package mgr  : %s\n' "$SYSTEM_PACKAGE_MANAGER"
  printf '\n'
}

require_supported_system() {
  if [[ "$SYSTEM_OS_FAMILY" == "unknown" ]]; then
    log_error "Unsupported or unknown Linux distribution: $SYSTEM_OS_ID"
    return 1
  fi

  if [[ "$SYSTEM_PACKAGE_MANAGER" == "unknown" ]]; then
    log_error "No supported package manager was found."
    return 1
  fi
}
