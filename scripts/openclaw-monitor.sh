#!/bin/bash
# openclaw-monitor.sh v2
# Gateway 状態スナップショット + 429監視
# - restart は一切しない
# - gateway-status.json を更新
# - JSONL / human log を追記

set -euo pipefail

LOCK_FILE="/tmp/openclaw-monitor.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

PATH="/home/yama/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin:/home/yama/.local/bin:${PATH:-}"
OPENCLAW="/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw"
SERVICE_NAME="openclaw-gateway.service"
SESSIONS_DIR="/home/yama/.openclaw/agents/main/sessions"
STATE_DIR="/home/yama/ws/state/rob-ops"
LOG_DIR="/home/yama/ws/logs/rob-ops"
STATUS_JSON="${STATE_DIR}/gateway-status.json"
EVENTS_JSONL="${LOG_DIR}/events.jsonl"
HUMAN_LOG="${LOG_DIR}/events-human.log"
LEGACY_LOG="/tmp/openclaw-monitor.log"

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
  python3 - <<'PY2'
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
PY2
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

json_dump_to_file() {
  local out_file="$1"
  shift
  PAYLOAD_PATH="$out_file" python3 - "$@" <<'PY2'
import json
import os
import sys
from pathlib import Path
payload = json.loads(sys.argv[1])
out = Path(os.environ["PAYLOAD_PATH"])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY2
}

RATE_LIMITED="false"
RECENT_ERRORS=0
RATE_ERRORS=0
RATE_MSG=""
GW_STATUS="ok"
GW_PID=""
CPU="0"
MEM_MB=0
SUB_STATE="unknown"
RPC_STATUS="unknown"
PORT_OWNER_PID=""
PORT_OWNER_COMM=""
TIMESTAMP="$(timestamp_jst)"

if systemctl --user show -p MainPID --value "$SERVICE_NAME" >/dev/null 2>&1; then
  GW_PID=$(systemctl --user show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || true)
  SUB_STATE=$(systemctl --user show -p SubState --value "$SERVICE_NAME" 2>/dev/null || true)
  if [[ -z "$GW_PID" || "$GW_PID" == "0" ]]; then
    GW_STATUS="down"
  fi
else
  GW_PID=$(pgrep -f 'dist/index.js gateway --port 18790' | head -1 || true)
  SUB_STATE="unknown"
  if [[ -z "$GW_PID" ]]; then
    GW_STATUS="down"
  fi
fi

if [[ -n "$GW_PID" && "$GW_PID" != "0" ]]; then
  local_rss=$(ps -o rss= -p "$GW_PID" 2>/dev/null | tr -d ' ' || true)
  local_cpu=$(ps -o %cpu= -p "$GW_PID" 2>/dev/null | tr -d ' ' || true)
  MEM_MB=$(( ${local_rss:-0} / 1024 ))
  CPU="${local_cpu:-0}"
fi

port_line=$(ss -ltnp '( sport = :18790 )' 2>/dev/null | awk 'NR>1 {print; exit}' || true)
if [[ -n "$port_line" ]]; then
  PORT_OWNER_PID=$(sed -n 's/.*pid=\([0-9]\+\).*/\1/p' <<<"$port_line" | head -1)
  PORT_OWNER_COMM=$(sed -n 's/.*users:((("\([^"]\+\)".*/\1/p' <<<"$port_line" | head -1)
fi

if [[ -x "$OPENCLAW" ]]; then
  rpc_output=$("$OPENCLAW" gateway status 2>/dev/null || true)
  if grep -qi 'RPC probe: ok' <<<"$rpc_output"; then
    RPC_STATUS="ok"
  elif [[ -n "$rpc_output" ]]; then
    RPC_STATUS="degraded"
  fi
fi

LATEST_SESSION=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1 || true)
if [[ -n "$LATEST_SESSION" ]]; then
  RECENT_ERRORS=$(tail -50 "$LATEST_SESSION" 2>/dev/null | grep -c '"isError":true' || true)
  RECENT_ERRORS=${RECENT_ERRORS:-0}
  RATE_ERRORS=$(tail -50 "$LATEST_SESSION" 2>/dev/null | grep -c '"status":429' || true)
  RATE_ERRORS=${RATE_ERRORS:-0}
  if [[ "$RATE_ERRORS" -gt 0 ]]; then
    RATE_LIMITED="true"
    RATE_MSG=$(tail -100 "$LATEST_SESSION" 2>/dev/null | grep -i '429\|rate.limit\|overloaded\|quota' | tail -1 | head -c 200 || true)
  fi
fi

status_payload=$(TIMESTAMP="$TIMESTAMP" GW_STATUS="$GW_STATUS" GW_PID="$GW_PID" SUB_STATE="$SUB_STATE" RPC_STATUS="$RPC_STATUS" MEM_MB="$MEM_MB" CPU="$CPU" PORT_OWNER_PID="$PORT_OWNER_PID" PORT_OWNER_COMM="$PORT_OWNER_COMM" RATE_LIMITED="$RATE_LIMITED" RECENT_ERRORS="$RECENT_ERRORS" RATE_ERRORS="$RATE_ERRORS" RATE_MSG="$RATE_MSG" LATEST_SESSION="$LATEST_SESSION" python3 - <<'PY2'
import json
import os
payload = {
    "timestamp": os.environ["TIMESTAMP"],
    "gateway": {
        "status": os.environ["GW_STATUS"],
        "pid": None if not os.environ["GW_PID"] or os.environ["GW_PID"] == "0" else int(os.environ["GW_PID"]),
        "subState": os.environ["SUB_STATE"],
        "rpcStatus": os.environ["RPC_STATUS"],
        "memoryMB": int(os.environ["MEM_MB"]),
        "cpu": os.environ["CPU"],
        "portOwnerPid": None if not os.environ["PORT_OWNER_PID"] else int(os.environ["PORT_OWNER_PID"]),
        "portOwnerComm": os.environ["PORT_OWNER_COMM"],
    },
    "api": {
        "rateLimited": os.environ["RATE_LIMITED"] == "true",
        "recentErrors": int(os.environ["RECENT_ERRORS"]),
        "rateErrors": int(os.environ["RATE_ERRORS"]),
        "lastError": os.environ["RATE_MSG"],
        "latestSession": os.environ["LATEST_SESSION"],
    },
}
print(json.dumps(payload, ensure_ascii=False))
PY2
)

json_dump_to_file "$STATUS_JSON" "$status_payload"

if [[ "$GW_STATUS" != "ok" ]]; then
  echo "[$TIMESTAMP] ⚠️ Gateway DOWN (snapshot only, no restart)" >> "$LEGACY_LOG"
  emit_event "observer" "openclaw-monitor" "gateway_down_snapshot" "critical" "observe" \
    "gateway process not found or MainPID=0" "$STATUS_JSON" "restart-arbiter evaluates separately" \
    "{\"gatewayStatus\": \"$GW_STATUS\", \"mainPid\": \"${GW_PID:-}\", \"subState\": \"${SUB_STATE:-}\"}"
  emit_human_log "CRITICAL" "openclaw-monitor" "gateway_down_snapshot" \
    "gateway process not found or MainPID=0" "snapshot only" "restart-arbiter evaluates separately"
elif [[ "$RATE_LIMITED" == "true" ]]; then
  echo "[$TIMESTAMP] ⚠️ Rate limit detected ($RATE_ERRORS recent occurrences)" >> "$LEGACY_LOG"
  emit_event "observer" "openclaw-monitor" "api_rate_limited" "warn" "observe" \
    "recent 429 detected in latest session log" "$LATEST_SESSION" "observe provider recovery" \
    "{\"rateErrors\": ${RATE_ERRORS:-0}, \"recentErrors\": ${RECENT_ERRORS:-0}, \"lastError\": $(python3 - "$RATE_MSG" <<'PY2'
import json, sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY2
)}"
  emit_human_log "WARN" "openclaw-monitor" "api_rate_limited" \
    "recent 429 detected in latest session log" "snapshot only" "observe provider recovery"
else
  minute=$(date '+%M')
  if [[ $((10#${minute} % 10)) -eq 0 ]]; then
    echo "[$TIMESTAMP] 🟢 OK | GW:${GW_PID:-?} | Mem:${MEM_MB:-?}MB | CPU:${CPU:-?}%" >> "$LEGACY_LOG"
    emit_event "observer" "openclaw-monitor" "gateway_snapshot_ok" "info" "observe" \
      "gateway snapshot updated" "$STATUS_JSON" "none" \
      "{\"mainPid\": \"${GW_PID:-}\", \"subState\": \"${SUB_STATE:-}\", \"rpcStatus\": \"${RPC_STATUS:-}\", \"memMb\": ${MEM_MB:-0}, \"cpu\": \"${CPU:-0}\"}"
  fi
fi

rotate_line_log "$LEGACY_LOG" 500 1000
rotate_line_log "$HUMAN_LOG" 2000 5000
