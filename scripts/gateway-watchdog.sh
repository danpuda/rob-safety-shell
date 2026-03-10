#!/usr/bin/env bash
# gateway-watchdog.sh — 最小版Gateway死活監視（通知のみ）
# 責務: healthエンドポイントにping → 連続失敗でTelegram通知
# restart責務はsystemdに委譲（Restart=on-failure）
set -euo pipefail

# --- 設定 ---
HEALTH_URL="${WATCHDOG_HEALTH_URL:-http://127.0.0.1:18790/health}"
FAIL_THRESHOLD="${WATCHDOG_FAIL_THRESHOLD:-3}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/ws/state/rob-ops}"
STATE_FILE="${STATE_DIR}/watchdog-fail-count"
EVENTS_JSONL="${WATCHDOG_LOG_DIR:-$HOME/ws/logs/rob-ops}/events.jsonl"
OPENCLAW="${WATCHDOG_OPENCLAW:-$(command -v openclaw)}"
TELEGRAM_CHANNEL="${WATCHDOG_TELEGRAM_CHANNEL:-telegram}"
TELEGRAM_TARGET="${WATCHDOG_TELEGRAM_TARGET:?WATCHDOG_TELEGRAM_TARGET must be set}"
COOLDOWN_FILE="${STATE_DIR}/watchdog-last-notify"
COOLDOWN_SECONDS="${WATCHDOG_COOLDOWN:-300}"  # 同じ障害で5分に1回まで

# --- ディレクトリ ---
mkdir -p "$STATE_DIR" "$(dirname "$EVENTS_JSONL")"

# --- health check ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  # 正常 → カウンタリセット
  echo "0" > "$STATE_FILE"
  exit 0
fi

# --- 失敗カウント ---
FAIL_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
[[ "$FAIL_COUNT" =~ ^[0-9]+$ ]] || FAIL_COUNT=0
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "$FAIL_COUNT" > "$STATE_FILE"

if [[ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]]; then
  exit 0  # 閾値未満 → まだ通知しない
fi

# --- クールダウンチェック ---
NOW=$(date +%s)
LAST_NOTIFY=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
if [[ $((NOW - LAST_NOTIFY)) -lt "$COOLDOWN_SECONDS" ]]; then
  exit 0  # 通知済み → 静か
fi

# --- 通知 ---
TITLE="🚨 Gateway DOWN (${FAIL_COUNT}回連続失敗)"
BODY="HTTP: ${HTTP_CODE} | threshold: ${FAIL_THRESHOLD}
systemdのRestart=on-failureが復旧を試みます。
手動確認: openclaw gateway status"

"$OPENCLAW" message send --channel "$TELEGRAM_CHANNEL" --target "$TELEGRAM_TARGET" \
  -m "${TITLE}

${BODY}" >/dev/null 2>&1 || \
  logger -t gateway-watchdog "WARN: Telegram notification failed" || true

# --- クールダウン更新（JSONL書き込み失敗でも通知洪水を防ぐ） ---
echo "$NOW" > "$COOLDOWN_FILE"

# --- JSONL記録 ---
TS=$(date -Iseconds)
printf '{"ts":"%s","layer":"observer","component":"gateway-watchdog","event":"gateway_down","severity":"critical","decision":"notify","evidence":{"httpCode":"%s","failCount":%d}}\n' \
  "$TS" "$HTTP_CODE" "$FAIL_COUNT" >> "$EVENTS_JSONL"
