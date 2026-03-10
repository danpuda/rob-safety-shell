#!/bin/bash
# config-drift-check.sh — Phase 1 minimal config drift detector
# - config drift を検知して知らせるだけ。restart しない（責務分離）
# - Phase 3 の布石として events.jsonl に 1 行出す
#
# FL3 review: Codex 43/100 + Sonnet 28/100 → 5件修正済み
#   C-1: vm.runInNewContext → JSON.parse
#   C-2: sensitive keys value masking
#   H-1/H-4: trap で無通知終了防止
#   H-2: known-good 自動初期化削除
#   H-3: systemd unit パス統一

set -euo pipefail

# --- エラー時も通知する（H-1/H-4 修正） ---
on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  emit_event "check_error" "error" \
    "config-drift-check failed at line ${line_no} with exit code ${exit_code}" \
    '{"error":"script_failure","line":"'"${line_no}"'","exit_code":'"${exit_code}"'}' 2>/dev/null || true
  send_notice "⚠️ Config drift check failed" \
    "time: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')
exit_code: ${exit_code}
line: ${line_no}
action: check script logs" 2>/dev/null || true
}
trap 'on_error ${LINENO}' ERR

LOCK_FILE="/tmp/config-drift-check.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

PATH="/home/yama/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
OPENCLAW="/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw"
CONFIG_PATH="/home/yama/.openclaw/openclaw.json"
KNOWN_GOOD_PATH="/home/yama/ws/state/rob-ops/known-good/openclaw.json"
STATE_DIR="/home/yama/ws/state/rob-ops"
LOG_DIR="/home/yama/ws/logs/rob-ops"
EVENTS_JSONL="${LOG_DIR}/events.jsonl"
PAIR_TARGET="telegram:pairing"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$KNOWN_GOOD_PATH")"

# --- known-good は手動初期化必須（H-2 修正） ---
if [[ ! -f "$KNOWN_GOOD_PATH" ]]; then
  echo "ERROR: known-good not initialized." >&2
  echo "Run: cp $CONFIG_PATH $KNOWN_GOOD_PATH" >&2
  exit 2
fi

ts_iso() { date --iso-8601=seconds; }
hash_file() { sha256sum "$1" | awk '{print $1}'; }

# --- sensitive keys のマスクリスト（C-2 修正） ---
SENSITIVE_PATTERNS="auth\\.tokens?|password|secret|api[_-]?key|credential|private[_-]?key"

emit_event() {
  local event_name="$1"
  local severity="$2"
  local reason="$3"
  local evidence_json="$4"
  EVENT_TS="$(ts_iso)" \
  EVENT_NAME="$event_name" \
  EVENT_SEVERITY="$severity" \
  EVENT_REASON="$reason" \
  EVENT_EVIDENCE_JSON="$evidence_json" \
  EVENTS_PATH="$EVENTS_JSONL" \
  python3 - <<'PY'
import json, os
from pathlib import Path
payload = {
    "ts": os.environ["EVENT_TS"],
    "layer": "observer",
    "component": "config-drift-check",
    "event": os.environ["EVENT_NAME"],
    "severity": os.environ["EVENT_SEVERITY"],
    "decision": "notify",
    "reason": os.environ["EVENT_REASON"],
    "target": "/home/yama/.openclaw/openclaw.json",
    "next_step": "review config and known-good diff",
    "evidence": json.loads(os.environ["EVENT_EVIDENCE_JSON"]),
}
path = Path(os.environ["EVENTS_PATH"])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
}

send_notice() {
  local title="$1"
  local body="$2"
  "$OPENCLAW" message send --channel "$PAIR_TARGET" --text "$title

$body" >/dev/null 2>&1 || \
    logger -t config-drift-check "WARN: Telegram notification failed for: $title"
}

CURRENT_HASH="$(hash_file "$CONFIG_PATH")"
KNOWN_HASH="$(hash_file "$KNOWN_GOOD_PATH")"
VALIDATE_RAW="$("$OPENCLAW" config validate --json 2>&1 || true)"
VALIDATE_OK="$(python3 - <<'PY' "$VALIDATE_RAW"
import json, sys
try:
    data = json.loads(sys.argv[1])
    print("true" if data.get("valid") is True else "false")
except Exception:
    print("false")
PY
)"

# --- C-1 修正: vm.runInNewContext → JSON.parse ---
# --- C-2 修正: sensitive keys の value を [REDACTED] に ---
DIFF_JSON="$(
CONFIG_PATH="$CONFIG_PATH" \
KNOWN_GOOD_PATH="$KNOWN_GOOD_PATH" \
SENSITIVE_PATTERNS="$SENSITIVE_PATTERNS" \
node <<'NODE'
const fs = require("node:fs");
const currentPath = process.env.CONFIG_PATH;
const knownPath = process.env.KNOWN_GOOD_PATH;
const sensitiveRe = new RegExp(process.env.SENSITIVE_PATTERNS, "i");
const dangerous = [
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
  "tools.elevated.enabled"
];
function load(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}
function get(obj, path) {
  return path.split(".").reduce((acc, k) => (acc != null && Object.prototype.hasOwnProperty.call(acc, k) ? acc[k] : undefined), obj);
}
function mask(key, val) {
  if (sensitiveRe.test(key) && val !== undefined && val !== null) return "[REDACTED]";
  return val;
}
const cur = load(currentPath);
const old = load(knownPath);
const changed = dangerous.flatMap((key) => {
  const before = get(old, key);
  const after = get(cur, key);
  if (before === undefined && after === undefined) return [];
  if (JSON.stringify(before) === JSON.stringify(after)) return [];
  return [{ key, before: mask(key, before), after: mask(key, after) }];
});
process.stdout.write(JSON.stringify({ changedDangerousKeys: changed }, null, 0));
NODE
)"

DANGEROUS_COUNT="$(echo "$DIFF_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("changedDangerousKeys",[])))')"

if [[ "$CURRENT_HASH" != "$KNOWN_HASH" || "$VALIDATE_OK" != "true" || "$DANGEROUS_COUNT" -gt 0 ]]; then
  KEYS="$(echo "$DIFF_JSON" | python3 -c 'import json,sys; print(", ".join(x["key"] for x in json.load(sys.stdin).get("changedDangerousKeys",[])[:10]))')"
  EVIDENCE_JSON="$(
    export CURRENT_HASH KNOWN_HASH VALIDATE_OK DANGEROUS_COUNT
    echo "$DIFF_JSON" | python3 -c '
import json,sys,os
diff = json.load(sys.stdin)
print(json.dumps({
    "configHash": os.environ["CURRENT_HASH"],
    "knownGoodHash": os.environ["KNOWN_HASH"],
    "validateOk": os.environ["VALIDATE_OK"] == "true",
    "dangerousChangeCount": int(os.environ["DANGEROUS_COUNT"]),
    "dangerousDiff": diff.get("changedDangerousKeys", []),
}, ensure_ascii=False))' )"
  emit_event "config_drift_detected" "critical" \
    "config drift / validate failure / dangerous key change detected" "$EVIDENCE_JSON"
  send_notice "🚨 Config drift detected" \
"time: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')
config: $CONFIG_PATH
known-good: $KNOWN_GOOD_PATH
validate_ok: $VALIDATE_OK
dangerous_change_count: $DANGEROUS_COUNT
keys: ${KEYS:-none}
action: review only (no restart)"
fi
