#!/usr/bin/env bash

STEP_ID="09"
STEP_NAME="Final verification"
STEP_DESCRIPTION="Recheck every previous step, self-heal failures, and send one Telegram success notice."

TG_NOTIFICATION_STATE="$STATE_DIR/telegram-success.state"
PREVIOUS_STEP_FILES=(
  "$SCRIPT_DIR/steps/00_base_environment.sh"
  "$SCRIPT_DIR/steps/01_nezha_agent.sh"
  "$SCRIPT_DIR/steps/02_configure_swap.sh"
  "$SCRIPT_DIR/steps/03_disable_firewall.sh"
  "$SCRIPT_DIR/steps/04_cloudflare_ddns.sh"
  "$SCRIPT_DIR/steps/05_warp_wireproxy.sh"
  "$SCRIPT_DIR/steps/06_v2bx_install.sh"
  "$SCRIPT_DIR/steps/07_v2bx_config.sh"
  "$SCRIPT_DIR/steps/08_periodic_reboot.sh"
)

verify_previous_steps() {
  local step_file
  for step_file in "${PREVIOUS_STEP_FILES[@]}"; do
    [[ -r "$step_file" ]] || return 1
    if ! (
      unset STEP_ID STEP_NAME STEP_DESCRIPTION
      unset -f step_check step_repair 2>/dev/null || true
      source "$step_file"
      step_check
    ); then
      return 1
    fi
  done
}

repair_previous_steps() {
  local step_file
  for step_file in "${PREVIOUS_STEP_FILES[@]}"; do
    [[ -r "$step_file" ]] || return 1
    if ! (run_with_retries "$STEP_RETRIES" run_step "$step_file"); then
      return 1
    fi
  done
}

telegram_notification_signature() {
  printf '%s\0' "$VERSION" \
    "${NZ_SERVER:-}" "${NZ_TLS:-}" "${NZ_CLIENT_SECRET:-}" "${NZ_UUID:-}" \
    "${NZ_INSTALL_URL:-}" "${CFKEY:-}" "${CFUSER:-}" "${CFRECORD_NAME:-}" \
    "${ApiHost:-}" "${ApiKey:-}" "${NodeID_anytls:-}" "${NodeID_hysteria2:-}" \
    "${TG_BOT_TOKEN:-}" "${TG_USER_ID:-}" | sha256sum | awk '{print $1}'
}

telegram_notification_current() {
  local saved_signature desired_signature

  [[ -r "$TG_NOTIFICATION_STATE" ]] || return 1
  read -r saved_signature < "$TG_NOTIFICATION_STATE" || return 1
  desired_signature="$(telegram_notification_signature)" || return 1
  [[ "$saved_signature" == "$desired_signature" ]]
}

send_telegram_success() {
  local message response attempt attempts="$COMMAND_RETRIES"

  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_USER_ID:-}" ]] || {
    log_error "TG_BOT_TOKEN and TG_USER_ID are required."
    return 1
  }

  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=3
  (( attempts >= 1 )) || attempts=1
  (( attempts <= 10 )) || attempts=10

  message="✅ VPS 开机脚本安装完成

📋 基本信息
━━━━━━━━━━━━━━━━
版本：$VERSION
主机：$(hostname)

🌐 服务状态
━━━━━━━━━━━━━━━━
✓ 哪吒探针：已安装
✓ Swap 交换：4GB (swappiness=10)
✓ 防火墙：已关闭
✓ Cloudflare DDNS：$CFRECORD_NAME
✓ WARP 代理：127.0.0.1:40000
✓ V2bX 节点：$NodeID_anytls, $NodeID_hysteria2
✓ 自动维护：V2bX 每分钟自检，WireProxy 每 1 小时重启并检测异常

🎉 所有服务运行正常！"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    response="$(curl -fsS --connect-timeout 15 --max-time 45 -X POST \
      --config /dev/fd/3 \
      --data-urlencode "chat_id=$TG_USER_ID" \
      --data-urlencode "text=$message" 3< <(
        printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_BOT_TOKEN"
      ) 2>/dev/null)" || true
    if jq -e '.ok == true' >/dev/null 2>&1 <<< "$response"; then
      log_success "Telegram success notification sent."
      return 0
    fi
    [[ "$attempt" -ge "$attempts" ]] || sleep "$RETRY_DELAY_SECONDS"
  done

  log_error "Telegram success notification failed."
  return 1
}

mark_telegram_notification() {
  local temp_path="${TG_NOTIFICATION_STATE}.$$"

  umask 077
  telegram_notification_signature > "$temp_path" || {
    rm -f "$temp_path"
    return 1
  }
  chmod 0600 "$temp_path" && mv -f "$temp_path" "$TG_NOTIFICATION_STATE"
}

step_check() {
  telegram_notification_current && verify_previous_steps
}

step_repair() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "Steps 00-08 will be rechecked and repaired before one Telegram success notice is sent."
    return 0
  fi

  if ! verify_previous_steps; then
    repair_previous_steps && verify_previous_steps || {
      log_error "Final verification found a step that could not be repaired."
      return 1
    }
  fi

  if telegram_notification_current; then
    return 0
  fi

  send_telegram_success && mark_telegram_notification
}
