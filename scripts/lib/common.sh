#!/bin/bash
# common.sh
# 共通関数ライブラリ
#
# Phase 1:
# - observer / recovery 系の共通ログ関数だけを集約
# - 監視ルール値（journal pattern, dangerous keys など）は各スクリプト内にまだハードコードのまま
# - TODO Phase 2: observer-rules.yaml からルール値を読む

set -euo pipefail

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

  : "${EVENTS_JSONL:?EVENTS_JSONL is not set}"

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

  : "${HUMAN_LOG:?HUMAN_LOG is not set}"

  printf '[%s][%s][%s/%s] event=%s reason=%s action=%s next=%s\n' \
    "$(timestamp_jst)" "$severity" "${LOG_LAYER_PREFIX:-observer}" "$component" \
    "$event_name" "$reason" "$action" "$next_step" >> "$HUMAN_LOG"
}
