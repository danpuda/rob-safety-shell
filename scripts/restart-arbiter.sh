#!/bin/bash
# restart-arbiter.sh
# 唯一の systemctl --user restart openclaw-gateway.service 実行者
# - 15分 cooldown
# - 1時間 3回上限
# - PID / port 照合
# - 前後スナップショット
# - JSONL / human log 出力

set -euo pipefail

LOCK_FILE="/tmp/restart-arbiter.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

PATH="/home/yama/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin:/home/yama/.local/bin:${PATH:-}"
OPENCLAW="/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw"
SERVICE_NAME="openclaw-gateway.service"
PORT="18790"

STATE_DIR="/home/yama/ws/state/rob-ops"
LOG_DIR="/home/yama/ws/logs/rob-ops"
EVENTS_JSONL="${LOG_DIR}/events.jsonl"
HUMAN_LOG="${LOG_DIR}/events-human.log"

RESTART_REQUEST_FILE="${STATE_DIR}/restart-request.json"
RESTART_HISTORY_FILE="${STATE_DIR}/restart-history.json"
RESTART_SNAPSHOT_DIR="${STATE_DIR}/restart-snapshots"
CONFIG_PATH="/home/yama/.openclaw/openclaw.json"
KNOWN_GOOD_PATH="${STATE_DIR}/known-good/openclaw.json"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$RESTART_SNAPSHOT_DIR"

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
  printf '[%s][%s][recovery/%s] event=%s reason=%s action=%s next=%s\n' \
    "$(timestamp_jst)" "$severity" "$component" "$event_name" "$reason" "$action" "$next_step" >> "$HUMAN_LOG"
}

ensure_history_file() {
  if [[ ! -f "$RESTART_HISTORY_FILE" ]]; then
    cat > "$RESTART_HISTORY_FILE" <<'EOF'
{
  "restarts": []
}
EOF
  fi
}

config_hash() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

main_pid() {
  systemctl --user show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || true
}

service_state() {
  systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true
}

sub_state() {
  systemctl --user show -p SubState --value "$SERVICE_NAME" 2>/dev/null || true
}

port_owner_pid() {
  ss -ltnp "( sport = :${PORT} )" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -1
}

port_owner_comm() {
  ss -ltnp "( sport = :${PORT} )" 2>/dev/null | sed -n 's/.*users:((("\([^"]\+\)".*/\1/p' | head -1
}

gateway_status_text() {
  if [[ -x "$OPENCLAW" ]]; then
    "$OPENCLAW" gateway status 2>/dev/null || true
  fi
}

channels_probe_text() {
  if [[ -x "$OPENCLAW" ]]; then
    "$OPENCLAW" channels status --probe 2>/dev/null || true
  fi
}

snapshot_json() {
  local phase="$1"
  local snapshot_file="$2"
  local now_iso
  now_iso="$(ts_iso)"
  local svc_state
  svc_state="$(service_state)"
  local svc_sub
  svc_sub="$(sub_state)"
  local pid
  pid="$(main_pid)"
  local owner_pid
  owner_pid="$(port_owner_pid || true)"
  local owner_comm
  owner_comm="$(port_owner_comm || true)"
  local gw_status
  gw_status="$(gateway_status_text)"
  local ch_probe
  ch_probe="$(channels_probe_text)"

  SNAPSHOT_PHASE="$phase" \
  SNAPSHOT_TS="$now_iso" \
  SNAPSHOT_SERVICE_STATE="$svc_state" \
  SNAPSHOT_SUB_STATE="$svc_sub" \
  SNAPSHOT_MAIN_PID="$pid" \
  SNAPSHOT_OWNER_PID="$owner_pid" \
  SNAPSHOT_OWNER_COMM="$owner_comm" \
  SNAPSHOT_GW_STATUS="$gw_status" \
  SNAPSHOT_CH_PROBE="$ch_probe" \
  SNAPSHOT_OUT="$snapshot_file" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "phase": os.environ["SNAPSHOT_PHASE"],
    "ts": os.environ["SNAPSHOT_TS"],
    "serviceState": os.environ["SNAPSHOT_SERVICE_STATE"],
    "subState": os.environ["SNAPSHOT_SUB_STATE"],
    "mainPid": os.environ["SNAPSHOT_MAIN_PID"],
    "portOwnerPid": os.environ["SNAPSHOT_OWNER_PID"],
    "portOwnerComm": os.environ["SNAPSHOT_OWNER_COMM"],
    "gatewayStatus": os.environ["SNAPSHOT_GW_STATUS"],
    "channelsProbe": os.environ["SNAPSHOT_CH_PROBE"],
}
out = Path(os.environ["SNAPSHOT_OUT"])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

history_count_since() {
  local since_seconds="$1"
  python3 - "$RESTART_HISTORY_FILE" "$since_seconds" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

path = Path(sys.argv[1])
seconds = int(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
items = data.get("restarts", [])

def parse_iso(s: str):
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)

now = datetime.now(timezone.utc).astimezone()
cutoff = now - timedelta(seconds=seconds)
count = 0
for item in items:
    ts = item.get("ts")
    if not ts:
        continue
    try:
        dt = parse_iso(ts)
    except Exception:
        continue
    if dt >= cutoff:
        count += 1
print(count)
PY
}

last_restart_age_seconds() {
  python3 - "$RESTART_HISTORY_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
items = data.get("restarts", [])
if not items:
    print(999999999)
    raise SystemExit(0)

def parse_iso(s: str):
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)

last_ts = items[-1].get("ts")
if not last_ts:
    print(999999999)
    raise SystemExit(0)
now = datetime.now(timezone.utc).astimezone()
last_dt = parse_iso(last_ts)
print(int((now - last_dt).total_seconds()))
PY
}

append_restart_history() {
  local ts="$1"
  local request_type="$2"
  local reason="$3"
  local pre_snapshot="$4"
  local post_snapshot="$5"
  python3 - "$RESTART_HISTORY_FILE" "$ts" "$request_type" "$reason" "$pre_snapshot" "$post_snapshot" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
ts, request_type, reason, pre_snapshot, post_snapshot = sys.argv[2:]
data = json.loads(path.read_text(encoding="utf-8"))
items = data.setdefault("restarts", [])
items.append({
    "ts": ts,
    "requestType": request_type,
    "reason": reason,
    "preSnapshot": pre_snapshot,
    "postSnapshot": post_snapshot,
})
# keep last 100
data["restarts"] = items[-100:]
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

delete_restart_request() {
  rm -f "$RESTART_REQUEST_FILE"
}

if [[ ! -f "$RESTART_REQUEST_FILE" ]]; then
  exit 0
fi

ensure_history_file

REQ_TYPE="$(python3 - "$RESTART_REQUEST_FILE" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get("requestType", "unknown"))
PY
)"
REQ_SEVERITY="$(python3 - "$RESTART_REQUEST_FILE" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get("severity", "warn"))
PY
)"
REQ_REASON="$(python3 - "$RESTART_REQUEST_FILE" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get("reason", ""))
PY
)"
REQ_EVIDENCE_JSON="$(python3 - "$RESTART_REQUEST_FILE" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(json.dumps(data.get("evidence", {}), ensure_ascii=False))
PY
)"

NOW_ISO="$(ts_iso)"
CURRENT_MAIN_PID="$(main_pid)"
CURRENT_PORT_OWNER_PID="$(port_owner_pid || true)"
CURRENT_PORT_OWNER_COMM="$(port_owner_comm || true)"
CURRENT_SERVICE_STATE="$(service_state)"
CURRENT_SUB_STATE="$(sub_state)"
CONFIG_CURRENT_HASH="$(config_hash "$CONFIG_PATH")"
CONFIG_KNOWN_HASH="$(config_hash "$KNOWN_GOOD_PATH")"

RESTARTS_LAST_15M="$(history_count_since 900)"
RESTARTS_LAST_1H="$(history_count_since 3600)"
LAST_RESTART_AGE="$(last_restart_age_seconds)"

DENY_REASON=""
NEXT_STEP="none"

if [[ -n "$CONFIG_CURRENT_HASH" && -n "$CONFIG_KNOWN_HASH" && "$CONFIG_CURRENT_HASH" != "$CONFIG_KNOWN_HASH" ]]; then
  DENY_REASON="config drift unresolved; restart denied until config reviewed"
  NEXT_STEP="run config-drift-check.sh and require human confirm"
elif [[ "$RESTARTS_LAST_1H" -ge 3 ]]; then
  DENY_REASON="restart budget exceeded: 3 restarts in last hour"
  NEXT_STEP="wait and inspect snapshots"
elif [[ "$LAST_RESTART_AGE" -lt 900 ]]; then
  DENY_REASON="restart cooldown active: last restart < 15 minutes ago"
  NEXT_STEP="wait for cooldown expiry"
elif [[ -n "$CURRENT_MAIN_PID" && "$CURRENT_MAIN_PID" != "0" && -n "$CURRENT_PORT_OWNER_PID" && "$CURRENT_MAIN_PID" != "$CURRENT_PORT_OWNER_PID" ]]; then
  : # allowed path for pid/port mismatch
elif [[ "$CURRENT_SERVICE_STATE" == "active" && "$REQ_TYPE" != "pid_port_mismatch" && "$REQ_TYPE" != "eaddrinuse" ]]; then
  DENY_REASON="service is active and request type does not justify restart"
  NEXT_STEP="observe only"
fi

if [[ -n "$DENY_REASON" ]]; then
  evidence_json=$(python3 - "$REQ_TYPE" "$REQ_REASON" "$CURRENT_SERVICE_STATE" "$CURRENT_MAIN_PID" "$CURRENT_PORT_OWNER_PID" "$CURRENT_PORT_OWNER_COMM" "$RESTARTS_LAST_15M" "$RESTARTS_LAST_1H" "$LAST_RESTART_AGE" <<'PY'
import json
import sys
payload = {
    "requestType": sys.argv[1],
    "requestReason": sys.argv[2],
    "serviceState": sys.argv[3],
    "mainPid": sys.argv[4],
    "portOwnerPid": sys.argv[5],
    "portOwnerComm": sys.argv[6],
    "restartsLast15m": int(sys.argv[7]),
    "restartsLast1h": int(sys.argv[8]),
    "lastRestartAgeSec": int(sys.argv[9]),
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
  emit_event "recovery" "restart-arbiter" "restart_denied" "warn" "deny" \
    "$DENY_REASON" "$SERVICE_NAME" "$NEXT_STEP" "$evidence_json"
  emit_human_log "WARN" "restart-arbiter" "restart_denied" "$DENY_REASON" "deny restart" "$NEXT_STEP"
  delete_restart_request
  rotate_line_log "$HUMAN_LOG" 2000 5000
  exit 0
fi

SNAP_TS="$(date '+%Y%m%d-%H%M%S')"
PRE_SNAPSHOT="${RESTART_SNAPSHOT_DIR}/pre-${SNAP_TS}.json"
POST_SNAPSHOT="${RESTART_SNAPSHOT_DIR}/post-${SNAP_TS}.json"

snapshot_json "pre-restart" "$PRE_SNAPSHOT"

pre_evidence_json=$(python3 - "$REQ_TYPE" "$REQ_REASON" "$PRE_SNAPSHOT" "$CURRENT_SERVICE_STATE" "$CURRENT_SUB_STATE" "$CURRENT_MAIN_PID" "$CURRENT_PORT_OWNER_PID" "$CURRENT_PORT_OWNER_COMM" <<'PY'
import json
import sys
payload = {
    "requestType": sys.argv[1],
    "requestReason": sys.argv[2],
    "preSnapshot": sys.argv[3],
    "serviceState": sys.argv[4],
    "subState": sys.argv[5],
    "mainPid": sys.argv[6],
    "portOwnerPid": sys.argv[7],
    "portOwnerComm": sys.argv[8],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)

emit_event "recovery" "restart-arbiter" "restart_begin" "critical" "restart" \
  "restart approved by arbiter" "$SERVICE_NAME" "systemctl --user restart" "$pre_evidence_json"
emit_human_log "CRITICAL" "restart-arbiter" "restart_begin" \
  "restart approved by arbiter" "systemctl --user restart ${SERVICE_NAME}" "collect post snapshot"

systemctl --user restart "$SERVICE_NAME"
sleep 5

POST_SERVICE_STATE="$(service_state)"
POST_SUB_STATE="$(sub_state)"
POST_MAIN_PID="$(main_pid)"
POST_PORT_OWNER_PID="$(port_owner_pid || true)"
POST_PORT_OWNER_COMM="$(port_owner_comm || true)"

snapshot_json "post-restart" "$POST_SNAPSHOT"
append_restart_history "$NOW_ISO" "$REQ_TYPE" "$REQ_REASON" "$PRE_SNAPSHOT" "$POST_SNAPSHOT"

post_evidence_json=$(python3 - "$REQ_TYPE" "$REQ_REASON" "$POST_SNAPSHOT" "$POST_SERVICE_STATE" "$POST_SUB_STATE" "$POST_MAIN_PID" "$POST_PORT_OWNER_PID" "$POST_PORT_OWNER_COMM" <<'PY'
import json
import sys
payload = {
    "requestType": sys.argv[1],
    "requestReason": sys.argv[2],
    "postSnapshot": sys.argv[3],
    "serviceState": sys.argv[4],
    "subState": sys.argv[5],
    "mainPid": sys.argv[6],
    "portOwnerPid": sys.argv[7],
    "portOwnerComm": sys.argv[8],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)

if [[ "$POST_SERVICE_STATE" == "active" ]]; then
  emit_event "recovery" "restart-arbiter" "restart_done" "info" "restart" \
    "restart completed" "$SERVICE_NAME" "observe next 60s" "$post_evidence_json"
  emit_human_log "INFO" "restart-arbiter" "restart_done" \
    "restart completed" "restart success" "observe next 60s"
else
  emit_event "recovery" "restart-arbiter" "restart_failed_postcheck" "critical" "restart" \
    "restart command completed but service not active after postcheck" "$SERVICE_NAME" "inspect snapshots and journal" "$post_evidence_json"
  emit_human_log "CRITICAL" "restart-arbiter" "restart_failed_postcheck" \
    "service not active after restart" "restart attempted" "inspect snapshots and journal"
fi

delete_restart_request
rotate_line_log "$HUMAN_LOG" 2000 5000
