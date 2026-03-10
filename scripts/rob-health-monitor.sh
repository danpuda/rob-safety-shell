#!/bin/bash
# rob-health-monitor.sh v3
# - 既存11パターン維持
# - config drift / PID-port mismatch を追加
# - Telegram通知から restart 案内を削除
# - restart 要求は restart-request.json に書く
# - JSONL / human log を追記

set -euo pipefail

LOCK_FILE="/tmp/rob-health-monitor.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

PATH="/home/yama/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin:/home/yama/.local/bin:${PATH:-}"
OPENCLAW="/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw"
SERVICE_NAME="openclaw-gateway.service"
CONFIG_PATH="/home/yama/.openclaw/openclaw.json"
KNOWN_GOOD_PATH="/home/yama/ws/state/rob-ops/known-good/openclaw.json"
STATE_DIR="/home/yama/ws/state/rob-ops"
LOG_DIR="/home/yama/ws/logs/rob-ops"
EVENTS_JSONL="${LOG_DIR}/events.jsonl"
HUMAN_LOG="${LOG_DIR}/events-human.log"
STATE_FILE="${STATE_DIR}/health-monitor-state.json"
RESTART_REQUEST_FILE="${STATE_DIR}/restart-request.json"
GATEWAY_STATUS_FILE="${STATE_DIR}/gateway-status.json"
LEGACY_LOG="/tmp/rob-health-monitor.log"
PAIR_TARGET="telegram:pairing"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$LEGACY_LOG")"

timestamp_jst() {
  TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S'
}

ts_iso() {
  date --iso-8601=seconds
}

rotate_line_log() {
  local file="$1"
  local keep_lines="$2"
  local max_lines="$3"
  if [[ -f "$file" ]]; then
    local lines
    lines=$(wc -l < "$file" 2>/dev/null || echo 0)
    if [[ "$lines" -gt "$max_lines" ]]; then
      tail -n "$keep_lines" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
  fi
}

json_escape() {
  python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY
}

emit_event() {
  local layer="$1"
  local component="$2"
  local event_name="$3"
  local severity="$4"
  local decision="$5"
  local reason="$6"
  local target="$7"
  local next_step="$8"
  local evidence_json="${9:-{}}"

  EVENT_TS="$(ts_iso)" \
  EVENT_LAYER="$layer" \
  EVENT_COMPONENT="$component" \
  EVENT_NAME="$event_name" \
  EVENT_SEVERITY="$severity" \
  EVENT_DECISION="$decision" \
  EVENT_REASON="$reason" \
  EVENT_TARGET="$target" \
  EVENT_NEXT_STEP="$next_step" \
  EVENT_EVIDENCE_JSON="$evidence_json" \
  EVENTS_PATH="$EVENTS_JSONL" \
  python3 - <<'PY'
import json
import os
from pathlib import Path
payload = {
    "ts": os.environ["EVENT_TS"],
    "layer": os.environ["EVENT_LAYER"],
    "component": os.environ["EVENT_COMPONENT"],
    "event": os.environ["EVENT_NAME"],
    "severity": os.environ["EVENT_SEVERITY"],
    "decision": os.environ["EVENT_DECISION"],
    "reason": os.environ["EVENT_REASON"],
    "target": os.environ["EVENT_TARGET"],
    "next_step": os.environ["EVENT_NEXT_STEP"],
    "evidence": json.loads(os.environ.get("EVENT_EVIDENCE_JSON", "{}")),
}
path = Path(os.environ["EVENTS_PATH"])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
}

emit_human_log() {
  local severity="$1"
  local component="$2"
  local event_name="$3"
  local reason="$4"
  local action="$5"
  local next_step="$6"
  printf '[%s][%s][observer/%s] event=%s reason=%s action=%s next=%s\n' \
    "$(timestamp_jst)" "$severity" "$component" "$event_name" "$reason" "$action" "$next_step" >> "$HUMAN_LOG"
}

send_telegram_notice() {
  local title="$1"
  local body="$2"
  if [[ ! -x "$OPENCLAW" ]]; then
    return 0
  fi
  local msg
  msg=$(cat <<EOF
$title

$body
EOF
)
  "$OPENCLAW" message send --channel "$PAIR_TARGET" --text "$msg" >/dev/null 2>&1 || true
}

ensure_state_file() {
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" <<'EOF'
{
  "alert_keys": {},
  "config_hash": "",
  "last_ok_at": ""
}
EOF
  fi
}

read_state_value() {
  local key="$1"
  python3 - "$STATE_FILE" "$key" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
print(data.get(key, ""))
PY
}

update_state_alert_key() {
  local alert_key="$1"
  local now_iso="$2"
  python3 - "$STATE_FILE" "$alert_key" "$now_iso" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
alert_key = sys.argv[2]
now_iso = sys.argv[3]
data = json.loads(path.read_text(encoding="utf-8"))
alerts = data.setdefault("alert_keys", {})
alerts[alert_key] = now_iso
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

update_state_config_hash() {
  local hash_value="$1"
  python3 - "$STATE_FILE" "$hash_value" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
hash_value = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
data["config_hash"] = hash_value
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

update_state_last_ok() {
  local now_iso="$1"
  python3 - "$STATE_FILE" "$now_iso" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
now_iso = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
data["last_ok_at"] = now_iso
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

should_emit_alert() {
  local alert_key="$1"
  local cooldown_sec="$2"
  python3 - "$STATE_FILE" "$alert_key" "$cooldown_sec" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

path = Path(sys.argv[1])
alert_key = sys.argv[2]
cooldown = int(sys.argv[3])
data = json.loads(path.read_text(encoding="utf-8"))
alerts = data.get("alert_keys", {})
last = alerts.get(alert_key)
if not last:
    print("yes")
    raise SystemExit(0)

def parse_iso(s: str) -> datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)

last_dt = parse_iso(last)
now_dt = datetime.now(timezone.utc).astimezone()
if now_dt - last_dt >= timedelta(seconds=cooldown):
    print("yes")
else:
    print("no")
PY
}

write_restart_request() {
  local request_type="$1"
  local severity="$2"
  local reason="$3"
  local evidence_json="$4"

  REQUEST_TYPE="$request_type" \
  REQUEST_SEVERITY="$severity" \
  REQUEST_REASON="$reason" \
  REQUEST_EVIDENCE_JSON="$evidence_json" \
  REQUEST_TS="$(ts_iso)" \
  REQUEST_FILE="$RESTART_REQUEST_FILE" \
  python3 - <<'PY'
import json
import os
from pathlib import Path
payload = {
    "requestedAt": os.environ["REQUEST_TS"],
    "requestType": os.environ["REQUEST_TYPE"],
    "severity": os.environ["REQUEST_SEVERITY"],
    "reason": os.environ["REQUEST_REASON"],
    "evidence": json.loads(os.environ["REQUEST_EVIDENCE_JSON"]),
    "requestedBy": "rob-health-monitor",
}
path = Path(os.environ["REQUEST_FILE"])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

get_config_hash() {
  if [[ -f "$CONFIG_PATH" ]]; then
    sha256sum "$CONFIG_PATH" | awk '{print $1}'
  else
    echo ""
  fi
}

get_file_hash() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

read_recent_journal() {
  journalctl --user -u "$SERVICE_NAME" --since "-70 sec" --no-pager 2>/dev/null || true
}

count_journal_pattern() {
  local pattern="$1"
  local since_arg="$2"
  journalctl --user -u "$SERVICE_NAME" --since "$since_arg" --no-pager 2>/dev/null | grep -Eic "$pattern" || true
}

get_main_pid() {
  systemctl --user show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || true
}

get_service_state() {
  systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true
}

get_port_owner_pid() {
  ss -ltnp '( sport = :18790 )' 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -1
}

get_port_owner_comm() {
  ss -ltnp '( sport = :18790 )' 2>/dev/null | sed -n 's/.*users:((("\([^"]\+\)".*/\1/p' | head -1
}

gateway_status_json_field() {
  local field="$1"
  if [[ ! -f "$GATEWAY_STATUS_FILE" ]]; then
    echo ""
    return 0
  fi
  python3 - "$GATEWAY_STATUS_FILE" "$field" <<'PY'
import json
import sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
field = sys.argv[2]
cur = data
for part in field.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print("")
        raise SystemExit(0)
print("" if cur is None else cur)
PY
}

ensure_state_file
NOW_ISO="$(ts_iso)"
NOW_JST="$(timestamp_jst)"
JOURNAL_TEXT="$(read_recent_journal)"
CURRENT_CONFIG_HASH="$(get_config_hash)"
KNOWN_GOOD_HASH="$(get_file_hash "$KNOWN_GOOD_PATH")"
MAIN_PID="$(get_main_pid)"
SERVICE_STATE="$(get_service_state)"
PORT_OWNER_PID="$(get_port_owner_pid || true)"
PORT_OWNER_COMM="$(get_port_owner_comm || true)"
LAST_OK_RPC="$(gateway_status_json_field "gateway.rpcStatus")"
LAST_OK_GATEWAY_STATUS="$(gateway_status_json_field "gateway.status")"

CONFIG_HASH_CHANGED="false"
LAST_STATE_HASH="$(read_state_value "config_hash")"
if [[ -n "$CURRENT_CONFIG_HASH" && "$CURRENT_CONFIG_HASH" != "$LAST_STATE_HASH" ]]; then
  CONFIG_HASH_CHANGED="true"
fi

# 既存11パターン
declare -A PATTERNS
PATTERNS["embedded_run_timeout"]='embedded run timeout'
PATTERNS["lane_wait_exceeded"]='lane wait exceeded'
PATTERNS["compaction_failed"]='compaction[^[:cntrl:]]*failed|compaction-diag[^[:cntrl:]]*outcome=failed'
PATTERNS["typing_ttl_reached"]='typing TTL reached'
PATTERNS["undici_null"]='undici.*null'
PATTERNS["eaddrinuse"]='EADDRINUSE|address already in use|another gateway instance is already listening'
PATTERNS["profile_timed_out"]='Profile.*timed out'
PATTERNS["overloaded"]='overloaded'
PATTERNS["health_monitor_restarting"]='health-monitor.*restarting'
PATTERNS["delivery_failed"]='Delivery failed|delivery.*failed'
PATTERNS["channel_probe_failed"]='channel probe failed|channels status.*failed'

declare -A SEVERITY
SEVERITY["embedded_run_timeout"]="critical"
SEVERITY["lane_wait_exceeded"]="high"
SEVERITY["compaction_failed"]="high"
SEVERITY["typing_ttl_reached"]="warn"
SEVERITY["undici_null"]="warn"
SEVERITY["eaddrinuse"]="critical"
SEVERITY["profile_timed_out"]="warn"
SEVERITY["overloaded"]="warn"
SEVERITY["health_monitor_restarting"]="warn"
SEVERITY["delivery_failed"]="warn"
SEVERITY["channel_probe_failed"]="warn"

declare -A RESTART_REQUIRED
RESTART_REQUIRED["embedded_run_timeout"]="true"
RESTART_REQUIRED["lane_wait_exceeded"]="false"
RESTART_REQUIRED["compaction_failed"]="false"
RESTART_REQUIRED["typing_ttl_reached"]="false"
RESTART_REQUIRED["undici_null"]="false"
RESTART_REQUIRED["eaddrinuse"]="true"
RESTART_REQUIRED["profile_timed_out"]="false"
RESTART_REQUIRED["overloaded"]="false"
RESTART_REQUIRED["health_monitor_restarting"]="false"
RESTART_REQUIRED["delivery_failed"]="false"
RESTART_REQUIRED["channel_probe_failed"]="false"

alerts_emitted=0

for key in "${!PATTERNS[@]}"; do
  pattern="${PATTERNS[$key]}"
  if grep -Eiq "$pattern" <<<"$JOURNAL_TEXT"; then
    if [[ "$(should_emit_alert "$key" 600)" == "yes" ]]; then
      matched_line=$(grep -Ei "$pattern" <<<"$JOURNAL_TEXT" | tail -1 | head -c 300 || true)
      sev="${SEVERITY[$key]}"
      need_restart="${RESTART_REQUIRED[$key]}"
      evidence_json=$(python3 - "$matched_line" "$MAIN_PID" "$PORT_OWNER_PID" "$SERVICE_STATE" <<'PY'
import json
import sys
payload = {
    "matchedLine": sys.argv[1],
    "mainPid": sys.argv[2],
    "portOwnerPid": sys.argv[3],
    "serviceState": sys.argv[4],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
      emit_event "observer" "rob-health-monitor" "$key" "$sev" "observe" \
        "journal pattern matched" "$SERVICE_NAME" "observe or escalate via arbiter" "$evidence_json"
      emit_human_log "$(tr '[:lower:]' '[:upper:]' <<<"$sev")" "rob-health-monitor" "$key" \
        "journal pattern matched" "notify and observe" "arbiter decides restart"
      send_telegram_notice "⚠️ Rob health alert: ${key}" \
        "time: ${NOW_JST}
severity: ${sev}
service: ${SERVICE_NAME}
pattern: ${pattern}
line: ${matched_line}
action: observe only / restart request handled by arbiter"

      update_state_alert_key "$key" "$NOW_ISO"
      alerts_emitted=$((alerts_emitted + 1))

      if [[ "$need_restart" == "true" ]]; then
        write_restart_request "$key" "$sev" "journal pattern matched: ${key}" "$evidence_json"
        emit_event "observer" "rob-health-monitor" "${key}_restart_requested" "$sev" "request_restart" \
          "restart requested for arbiter" "$RESTART_REQUEST_FILE" "restart-arbiter evaluates request" "$evidence_json"
        emit_human_log "$(tr '[:lower:]' '[:upper:]' <<<"$sev")" "rob-health-monitor" "${key}_restart_requested" \
          "restart requested for arbiter" "write restart-request.json" "restart-arbiter evaluates request"
      fi
    fi
  fi
done

# config drift 検知
if [[ -n "$CURRENT_CONFIG_HASH" && -n "$KNOWN_GOOD_HASH" && "$CURRENT_CONFIG_HASH" != "$KNOWN_GOOD_HASH" ]]; then
  if [[ "$(should_emit_alert "config_drift" 600)" == "yes" ]]; then
    evidence_json=$(python3 - "$CURRENT_CONFIG_HASH" "$KNOWN_GOOD_HASH" "$CONFIG_PATH" "$KNOWN_GOOD_PATH" <<'PY'
import json
import sys
payload = {
    "configHash": sys.argv[1],
    "knownGoodHash": sys.argv[2],
    "configPath": sys.argv[3],
    "knownGoodPath": sys.argv[4],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
    emit_event "observer" "rob-health-monitor" "config_drift" "critical" "notify" \
      "openclaw.json hash differs from known-good" "$CONFIG_PATH" "run config-drift-check.sh and require review" "$evidence_json"
    emit_human_log "CRITICAL" "rob-health-monitor" "config_drift" \
      "openclaw.json hash differs from known-good" "notify only" "run config-drift-check.sh and require review"
    send_telegram_notice "🚨 Rob health alert: config_drift" \
      "time: ${NOW_JST}
config: ${CONFIG_PATH}
known-good: ${KNOWN_GOOD_PATH}
action: review required (no direct restart guidance)"
    update_state_alert_key "config_drift" "$NOW_ISO"
    alerts_emitted=$((alerts_emitted + 1))
  fi
fi

# PID / port 不整合検知
if [[ -n "$MAIN_PID" && "$MAIN_PID" != "0" && -n "$PORT_OWNER_PID" && "$MAIN_PID" != "$PORT_OWNER_PID" ]]; then
  if [[ "$(should_emit_alert "pid_port_mismatch" 600)" == "yes" ]]; then
    evidence_json=$(python3 - "$MAIN_PID" "$PORT_OWNER_PID" "$PORT_OWNER_COMM" "$SERVICE_STATE" <<'PY'
import json
import sys
payload = {
    "mainPid": sys.argv[1],
    "portOwnerPid": sys.argv[2],
    "portOwnerComm": sys.argv[3],
    "serviceState": sys.argv[4],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
    emit_event "observer" "rob-health-monitor" "pid_port_mismatch" "critical" "request_restart" \
      "systemd MainPID and port 18790 owner mismatch" "$SERVICE_NAME" "restart-arbiter evaluates request" "$evidence_json"
    emit_human_log "CRITICAL" "rob-health-monitor" "pid_port_mismatch" \
      "systemd MainPID and port 18790 owner mismatch" "write restart-request.json" "restart-arbiter evaluates request"
    send_telegram_notice "🚨 Rob health alert: pid_port_mismatch" \
      "time: ${NOW_JST}
service: ${SERVICE_NAME}
mainPid: ${MAIN_PID}
portOwnerPid: ${PORT_OWNER_PID}
portOwnerComm: ${PORT_OWNER_COMM}
action: arbiter review requested"
    write_restart_request "pid_port_mismatch" "critical" "systemd MainPID and port owner mismatch" "$evidence_json"
    update_state_alert_key "pid_port_mismatch" "$NOW_ISO"
    alerts_emitted=$((alerts_emitted + 1))
  fi
fi

# inactive / failed service の観測
if [[ "$SERVICE_STATE" != "active" ]]; then
  if [[ "$(should_emit_alert "service_inactive" 300)" == "yes" ]]; then
    evidence_json=$(python3 - "$SERVICE_STATE" "$MAIN_PID" "$PORT_OWNER_PID" "$LAST_OK_GATEWAY_STATUS" "$LAST_OK_RPC" <<'PY'
import json
import sys
payload = {
    "serviceState": sys.argv[1],
    "mainPid": sys.argv[2],
    "portOwnerPid": sys.argv[3],
    "gatewaySnapshotStatus": sys.argv[4],
    "gatewaySnapshotRpcStatus": sys.argv[5],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
    emit_event "observer" "rob-health-monitor" "service_inactive" "critical" "request_restart" \
      "openclaw-gateway.service is not active" "$SERVICE_NAME" "restart-arbiter evaluates request" "$evidence_json"
    emit_human_log "CRITICAL" "rob-health-monitor" "service_inactive" \
      "openclaw-gateway.service is not active" "write restart-request.json" "restart-arbiter evaluates request"
    send_telegram_notice "🚨 Rob health alert: service_inactive" \
      "time: ${NOW_JST}
service: ${SERVICE_NAME}
state: ${SERVICE_STATE}
action: arbiter review requested"
    write_restart_request "service_inactive" "critical" "service is not active" "$evidence_json"
    update_state_alert_key "service_inactive" "$NOW_ISO"
    alerts_emitted=$((alerts_emitted + 1))
  fi
fi

# 軽い正常系 heartbeat
if [[ "$alerts_emitted" -eq 0 ]]; then
  minute=$(date '+%M')
  if [[ $((10#${minute} % 10)) -eq 0 ]]; then
    emit_event "observer" "rob-health-monitor" "health_monitor_ok" "info" "observe" \
      "no alert patterns matched in recent journal window" "$SERVICE_NAME" "none" \
      "{\"serviceState\": $(json_escape "$SERVICE_STATE"), \"mainPid\": $(json_escape "$MAIN_PID"), \"portOwnerPid\": $(json_escape "$PORT_OWNER_PID")}"
    emit_human_log "INFO" "rob-health-monitor" "health_monitor_ok" \
      "no alert patterns matched in recent journal window" "none" "none"
  fi
  update_state_last_ok "$NOW_ISO"
fi

if [[ "$CONFIG_HASH_CHANGED" == "true" && -n "$CURRENT_CONFIG_HASH" ]]; then
  update_state_config_hash "$CURRENT_CONFIG_HASH"
fi

printf '[%s] alerts=%s service=%s mainPid=%s portOwnerPid=%s configHashChanged=%s\n' \
  "$NOW_JST" "$alerts_emitted" "$SERVICE_STATE" "${MAIN_PID:-}" "${PORT_OWNER_PID:-}" "$CONFIG_HASH_CHANGED" >> "$LEGACY_LOG"

rotate_line_log "$LEGACY_LOG" 500 1000
rotate_line_log "$HUMAN_LOG" 2000 5000
