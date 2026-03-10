#!/bin/bash
# config-drift-check.sh (minimal)
# Phase 1:
# - config drift を検知して知らせるだけ
# - restart しない
# - human log / dedupe / rollback / restart request は持たない
# - Phase 3 の布石として events.jsonl に 1 行出す

set -euo pipefail

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
[[ -f "$KNOWN_GOOD_PATH" ]] || cp -n "$CONFIG_PATH" "$KNOWN_GOOD_PATH"

ts_iso() { date --iso-8601=seconds; }
hash_file() { sha256sum "$1" | awk '{print $1}'; }

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

$body" >/dev/null 2>&1 || true
}

CURRENT_HASH="$(hash_file "$CONFIG_PATH")"
KNOWN_HASH="$(hash_file "$KNOWN_GOOD_PATH")"
VALIDATE_RAW="$("$OPENCLAW" config validate --json 2>&1 || true)"
VALIDATE_OK="$(python3 - <<'PY' "$VALIDATE_RAW"
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
    print("true" if data.get("valid") is True else "false")
except Exception:
    print("false")
PY
)"

DIFF_JSON="$(
CONFIG_PATH="$CONFIG_PATH" KNOWN_GOOD_PATH="$KNOWN_GOOD_PATH" node <<'NODE'
const fs = require("node:fs");
const vm = require("node:vm");
const currentPath = process.env.CONFIG_PATH;
const knownPath = process.env.KNOWN_GOOD_PATH;
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
  const text = fs.readFileSync(p, "utf8");
  return vm.runInNewContext("(" + text + ")", Object.create(null), { timeout: 1000 });
}
function get(obj, path) {
  return path.split(".").reduce((acc, k) => (acc && Object.prototype.hasOwnProperty.call(acc, k) ? acc[k] : null), obj);
}
const cur = load(currentPath);
const old = load(knownPath);
const changed = dangerous.flatMap((key) => {
  const before = get(old, key);
  const after = get(cur, key);
  return JSON.stringify(before) === JSON.stringify(after) ? [] : [{ key, before, after }];
});
process.stdout.write(JSON.stringify({ changedDangerousKeys: changed }, null, 0));
NODE
)"
DANGEROUS_COUNT="$(python3 - <<'PY' "$DIFF_JSON"
import json, sys
print(len(json.loads(sys.argv[1]).get("changedDangerousKeys", [])))
PY
)"

if [[ "$CURRENT_HASH" != "$KNOWN_HASH" || "$VALIDATE_OK" != "true" || "$DANGEROUS_COUNT" -gt 0 ]]; then
  KEYS="$(python3 - <<'PY' "$DIFF_JSON"
import json, sys
keys = [x["key"] for x in json.loads(sys.argv[1]).get("changedDangerousKeys", [])]
print(", ".join(keys[:10]))
PY
)"
  EVIDENCE_JSON="$(python3 - <<'PY' "$CURRENT_HASH" "$KNOWN_HASH" "$VALIDATE_OK" "$DANGEROUS_COUNT" "$DIFF_JSON"
import json, sys
payload = {
    "configHash": sys.argv[1],
    "knownGoodHash": sys.argv[2],
    "validateOk": sys.argv[3] == "true",
    "dangerousChangeCount": int(sys.argv[4]),
    "dangerousDiff": json.loads(sys.argv[5]).get("changedDangerousKeys", []),
}
print(json.dumps(payload, ensure_ascii=False))
PY
)"
  emit_event "config_drift_detected" "critical" "config drift / validate failure / dangerous key change detected" "$EVIDENCE_JSON"
  send_notice "🚨 Config drift detected" \
"time: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')
config: $CONFIG_PATH
known-good: $KNOWN_GOOD_PATH
validate_ok: $VALIDATE_OK
dangerous_change_count: $DANGEROUS_COUNT
keys: ${KEYS:-none}
action: review only (no restart)"
fi
