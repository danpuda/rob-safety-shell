#!/bin/bash
# config-drift-check.sh
# - /home/yama/.openclaw/openclaw.json の sha256sum 監視
# - known-good と比較
# - openclaw config validate --json 実行
# - drift 検知時は JSONL + Telegram 通知
# - 危険キー差分を抽出

set -euo pipefail

LOCK_FILE="/tmp/config-drift-check.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

PATH="/home/yama/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin:/home/yama/.local/bin:${PATH:-}"
OPENCLAW="/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw"

CONFIG_PATH="/home/yama/.openclaw/openclaw.json"
STATE_DIR="/home/yama/ws/state/rob-ops"
LOG_DIR="/home/yama/ws/logs/rob-ops"
KNOWN_GOOD_DIR="${STATE_DIR}/known-good"
KNOWN_GOOD_PATH="${KNOWN_GOOD_DIR}/openclaw.json"
STATE_FILE="${STATE_DIR}/config-drift-state.json"
LAST_VALIDATE_JSON="${STATE_DIR}/config-validate-last.json"
LAST_DIFF_JSON="${STATE_DIR}/config-diff-last.json"
EVENTS_JSONL="${LOG_DIR}/events.jsonl"
HUMAN_LOG="${LOG_DIR}/events-human.log"
LEGACY_LOG="/tmp/config-drift-check.log"
PAIR_TARGET="telegram:pairing"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$KNOWN_GOOD_DIR" "$(dirname "$LEGACY_LOG")"

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
  "lastConfigHash": "",
  "lastKnownGoodHash": "",
  "lastDriftAlertAt": "",
  "lastValidateAlertAt": "",
  "lastDangerAlertAt": ""
}
EOF
  fi
}

read_state_field() {
  local key="$1"
  python3 - "$STATE_FILE" "$key" <<'PY'
import json
import sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get(sys.argv[2], ""))
PY
}

update_state_fields() {
  python3 - "$STATE_FILE" "$@" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
updates = sys.argv[2:]
data = json.loads(path.read_text(encoding="utf-8"))

for pair in updates:
    key, value = pair.split("=", 1)
    data[key] = value

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

should_emit_alert() {
  local field_name="$1"
  local cooldown_sec="$2"
  python3 - "$STATE_FILE" "$field_name" "$cooldown_sec" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

path = Path(sys.argv[1])
field_name = sys.argv[2]
cooldown = int(sys.argv[3])
data = json.loads(path.read_text(encoding="utf-8"))
last = data.get(field_name)
if not last:
    print("yes")
    raise SystemExit(0)

def parse_iso(s: str):
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)

last_dt = parse_iso(last)
now_dt = datetime.now(timezone.utc).astimezone()
print("yes" if now_dt - last_dt >= timedelta(seconds=cooldown) else "no")
PY
}

file_hash() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

run_validate() {
  if [[ ! -x "$OPENCLAW" ]]; then
    cat > "$LAST_VALIDATE_JSON" <<'EOF'
{"ok": false, "error": "openclaw binary not found", "raw": ""}
EOF
    return 1
  fi

  local out
  local rc=0
  out=$("$OPENCLAW" config validate --json 2>&1) || rc=$?
  VALIDATE_OUT="$out" VALIDATE_RC="$rc" VALIDATE_PATH="$LAST_VALIDATE_JSON" python3 - <<'PY'
import json
import os
from pathlib import Path

raw = os.environ["VALIDATE_OUT"]
rc = int(os.environ["VALIDATE_RC"])
ok = False
parsed = None
try:
    parsed = json.loads(raw) if raw.strip() else None
    if isinstance(parsed, dict):
        # 公式 docs bundle 上の validate 出力差分がありえるため、
        # ok/valid/success のどれかを優先評価
        if parsed.get("ok") is True or parsed.get("valid") is True or parsed.get("success") is True:
            ok = True
        elif parsed.get("ok") is False or parsed.get("valid") is False or parsed.get("success") is False:
            ok = False
        else:
            ok = (rc == 0)
    else:
        ok = (rc == 0)
except Exception:
    parsed = None
    ok = (rc == 0)

payload = {
    "ok": ok,
    "rc": rc,
    "parsed": parsed,
    "raw": raw,
}
Path(os.environ["VALIDATE_PATH"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8"
)
PY
  [[ "$rc" -eq 0 ]]
}

diff_dangerous_keys() {
  python3 - "$CONFIG_PATH" "$KNOWN_GOOD_PATH" "$LAST_DIFF_JSON" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
known_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])

dangerous_keys = [
    "agents.defaults.compaction.mode",
    "agents.defaults.compaction.reserveTokensFloor",
    "agents.defaults.compaction.memoryFlush.enabled",
    "agents.defaults.contextPruning.mode",
    "agents.defaults.contextPruning.ttl",
    "agents.defaults.tools.loopDetection.enabled",
    "agents.defaults.tools.loopDetection.suspiciousPrefixes",
    "gateway.auth.mode",
    "gateway.auth.tokens",
    "gateway.bind",
    "gateway.controlUi.enabled",
    "gateway.controlUi.allowedOrigins",
    "channels.telegram.enabled",
    "channels.discord.enabled",
    "channels.whatsapp.enabled",
    "channels.msteams.enabled",
    "channels.telegram.dmPolicy",
    "channels.telegram.groupPolicy",
    "session.dmScope",
    "tools.elevated.enabled",
]

def load(path: Path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))

def get_path(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur

cur = load(config_path)
old = load(known_path)

changed = []
for key in dangerous_keys:
    before = get_path(old, key)
    after = get_path(cur, key)
    if before != after:
        changed.append({
            "key": key,
            "before": before,
            "after": after,
        })

payload = {
    "dangerousKeys": dangerous_keys,
    "changedDangerousKeys": changed,
    "hasDangerousChanges": len(changed) > 0,
}
out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
PY
}

bootstrap_known_good_if_missing() {
  if [[ ! -f "$KNOWN_GOOD_PATH" && -f "$CONFIG_PATH" ]]; then
    cp "$CONFIG_PATH" "$KNOWN_GOOD_PATH"
    emit_event "observer" "config-drift-check" "known_good_bootstrapped" "info" "observe" \
      "known-good config was missing; bootstrapped from current config" "$KNOWN_GOOD_PATH" "review bootstrap source" \
      "{\"configPath\": \"$CONFIG_PATH\", \"knownGoodPath\": \"$KNOWN_GOOD_PATH\"}"
    emit_human_log "INFO" "config-drift-check" "known_good_bootstrapped" \
      "known-good config was missing; bootstrapped from current config" "copy file" "review bootstrap source"
  fi
}

ensure_state_file
bootstrap_known_good_if_missing

CURRENT_HASH="$(file_hash "$CONFIG_PATH")"
KNOWN_HASH="$(file_hash "$KNOWN_GOOD_PATH")"
NOW_ISO="$(ts_iso)"
NOW_JST="$(timestamp_jst)"

VALIDATE_OK="false"
if run_validate; then
  VALIDATE_OK="true"
fi

DIFF_JSON="$(diff_dangerous_keys)"
HAS_DANGEROUS_CHANGES="$(python3 - "$LAST_DIFF_JSON" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("true" if data.get("hasDangerousChanges") else "false")
PY
)"
DANGEROUS_COUNT="$(python3 - "$LAST_DIFF_JSON" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(len(data.get("changedDangerousKeys", [])))
PY
)"

drift_detected="false"
if [[ -n "$CURRENT_HASH" && -n "$KNOWN_HASH" && "$CURRENT_HASH" != "$KNOWN_HASH" ]]; then
  drift_detected="true"
fi

alerts=0

if [[ "$drift_detected" == "true" ]]; then
  if [[ "$(should_emit_alert "lastDriftAlertAt" 600)" == "yes" ]]; then
    evidence_json=$(python3 - "$CURRENT_HASH" "$KNOWN_HASH" "$CONFIG_PATH" "$KNOWN_GOOD_PATH" "$DANGEROUS_COUNT" <<'PY'
import json
import sys
payload = {
    "configHash": sys.argv[1],
    "knownGoodHash": sys.argv[2],
    "configPath": sys.argv[3],
    "knownGoodPath": sys.argv[4],
    "dangerousChangeCount": int(sys.argv[5]),
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
    emit_event "observer" "config-drift-check" "config_drift_detected" "critical" "notify" \
      "openclaw.json differs from known-good" "$CONFIG_PATH" "require human review before restart" "$evidence_json"
    emit_human_log "CRITICAL" "config-drift-check" "config_drift_detected" \
      "openclaw.json differs from known-good" "notify only" "require human review before restart"
    send_telegram_notice "🚨 Config drift detected" \
      "time: ${NOW_JST}
config: ${CONFIG_PATH}
known-good: ${KNOWN_GOOD_PATH}
dangerousChangeCount: ${DANGEROUS_COUNT}
action: review required before restart/rollback"
    update_state_fields "lastDriftAlertAt=${NOW_ISO}"
    alerts=$((alerts + 1))
  fi
fi

if [[ "$VALIDATE_OK" != "true" ]]; then
  if [[ "$(should_emit_alert "lastValidateAlertAt" 600)" == "yes" ]]; then
    validate_raw=$(python3 - "$LAST_VALIDATE_JSON" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
raw = data.get("raw", "")
print(raw[:500])
PY
)
    evidence_json=$(python3 - "$LAST_VALIDATE_JSON" "$CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path
validate = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
payload = {
    "configPath": sys.argv[2],
    "validateOk": validate.get("ok"),
    "validateRc": validate.get("rc"),
    "validateParsed": validate.get("parsed"),
    "validateRaw": validate.get("raw", "")[:500],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
    emit_event "observer" "config-drift-check" "config_validate_failed" "critical" "notify" \
      "openclaw config validate --json failed" "$CONFIG_PATH" "require manual fix before restart" "$evidence_json"
    emit_human_log "CRITICAL" "config-drift-check" "config_validate_failed" \
      "openclaw config validate --json failed" "notify only" "require manual fix before restart"
    send_telegram_notice "🚨 Config validation failed" \
      "time: ${NOW_JST}
config: ${CONFIG_PATH}
action: fix config before restart
summary: ${validate_raw}"
    update_state_fields "lastValidateAlertAt=${NOW_ISO}"
    alerts=$((alerts + 1))
  fi
fi

if [[ "$HAS_DANGEROUS_CHANGES" == "true" ]]; then
  if [[ "$(should_emit_alert "lastDangerAlertAt" 600)" == "yes" ]]; then
    changed_keys="$(python3 - "$LAST_DIFF_JSON" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
keys = [item["key"] for item in data.get("changedDangerousKeys", [])]
print(", ".join(keys[:12]))
PY
)"
    evidence_json="$(cat "$LAST_DIFF_JSON")"
    emit_event "observer" "config-drift-check" "dangerous_config_keys_changed" "critical" "notify" \
      "dangerous config keys changed relative to known-good" "$CONFIG_PATH" "require human confirm" "$evidence_json"
    emit_human_log "CRITICAL" "config-drift-check" "dangerous_config_keys_changed" \
      "dangerous config keys changed relative to known-good" "notify only" "require human confirm"
    send_telegram_notice "⚠️ Dangerous config keys changed" \
      "time: ${NOW_JST}
count: ${DANGEROUS_COUNT}
keys: ${changed_keys}
action: human confirm required"
    update_state_fields "lastDangerAlertAt=${NOW_ISO}"
    alerts=$((alerts + 1))
  fi
fi

update_state_fields \
  "lastConfigHash=${CURRENT_HASH}" \
  "lastKnownGoodHash=${KNOWN_HASH}"

if [[ "$alerts" -eq 0 ]]; then
  minute=$(date '+%M')
  if [[ $((10#${minute} % 10)) -eq 0 ]]; then
    emit_event "observer" "config-drift-check" "config_drift_ok" "info" "observe" \
      "config matches known-good or no new critical drift found" "$CONFIG_PATH" "none" \
      "{\"configHash\": \"$CURRENT_HASH\", \"knownGoodHash\": \"$KNOWN_HASH\", \"validateOk\": ${VALIDATE_OK}}"
    emit_human_log "INFO" "config-drift-check" "config_drift_ok" \
      "config matches known-good or no new critical drift found" "none" "none"
  fi
fi

printf '[%s] alerts=%s drift=%s validate_ok=%s dangerous_changes=%s current_hash=%s known_hash=%s\n' \
  "$NOW_JST" "$alerts" "$drift_detected" "$VALIDATE_OK" "$HAS_DANGEROUS_CHANGES" "${CURRENT_HASH:-}" "${KNOWN_HASH:-}" >> "$LEGACY_LOG"

rotate_line_log "$LEGACY_LOG" 500 1000
rotate_line_log "$HUMAN_LOG" 2000 5000
