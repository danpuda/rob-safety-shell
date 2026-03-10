#!/bin/bash
# silent-hang-monitor.sh — Phase 2: Gateway無言停止検知
# 責務: Gateway RPC + Channel probe + reply-age + web burst監査
# 設計: GPT-5.4 返信10
set -euo pipefail
trap 'on_error ${LINENO}' ERR

LOCK_FILE="${LOCK_FILE:-/tmp/silent-hang-monitor.lock}"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

OPENCLAW_BIN="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null)}"
: "${OPENCLAW_BIN:?openclaw binary not found in PATH, set OPENCLAW_BIN}"
SESSION_DIR="${SESSION_DIR:-$HOME/.openclaw/agents/main/sessions}"
STATE_DIR="${STATE_DIR:-$HOME/ws/state/rob-ops}"
LOG_DIR="${LOG_DIR:-$HOME/ws/logs/rob-ops}"
EVENTS_JSONL="${EVENTS_JSONL:-$LOG_DIR/events.jsonl}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:?TELEGRAM_TARGET must be set}"

REPLY_AGE_SEC="${REPLY_AGE_SEC:-420}"
ACTIVE_WINDOW_SEC="${ACTIVE_WINDOW_SEC:-900}"
QUIET_START_HOUR="${QUIET_START_HOUR:-8}"
QUIET_END_HOUR="${QUIET_END_HOUR:-14}"
WEB_WINDOW_SEC="${WEB_WINDOW_SEC:-180}"
WEB_BURST_THRESHOLD="${WEB_BURST_THRESHOLD:-2}"
SAMPLE_EVERY_MIN="${SAMPLE_EVERY_MIN:-5}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

ts_iso() { date --iso-8601=seconds; }
ts_jst_hm() { TZ=Asia/Tokyo date '+%H:%M'; }

on_error() {
  local line="$1"
  emit_event "silent_hang_monitor_error" "critical" "notify" \
    "silent-hang-monitor failed at line $line" \
    "{\"line\": $line}"
}

emit_event() {
  local event_name="$1"
  local severity="$2"
  local decision="$3"
  local reason="$4"
  local evidence_json="$5"

  EVENT_TS="$(ts_iso)" \
  EVENT_NAME="$event_name" \
  EVENT_SEVERITY="$severity" \
  EVENT_DECISION="$decision" \
  EVENT_REASON="$reason" \
  EVENT_EVIDENCE_JSON="$evidence_json" \
  EVENTS_PATH="$EVENTS_JSONL" \
  python3 - <<'PY'
import json, os
from pathlib import Path

payload = {
    "ts": os.environ["EVENT_TS"],
    "layer": "observer",
    "component": "silent-hang-monitor",
    "event": os.environ["EVENT_NAME"],
    "severity": os.environ["EVENT_SEVERITY"],
    "decision": os.environ["EVENT_DECISION"],
    "reason": os.environ["EVENT_REASON"],
    "target": os.environ.get("SESSION_DIR", "sessions"),
    "next_step": "review gateway/channel/session state",
    "evidence": json.loads(os.environ["EVENT_EVIDENCE_JSON"]),
}
path = Path(os.environ["EVENTS_PATH"])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
}

NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-600}"  # 同じ種類の通知は10分に1回まで

notify() {
  local msg="$1"
  local kind="${2:-general}"
  local cooldown_file="$STATE_DIR/notify-cooldown-${kind}"
  local now
  now="$(date +%s)"
  if [ -f "$cooldown_file" ]; then
    local last
    last="$(cat "$cooldown_file" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt "$NOTIFY_COOLDOWN" ]; then
      return 0  # cooldown中
    fi
  fi
  "$OPENCLAW_BIN" message send --channel telegram --target "$TELEGRAM_TARGET" -m "$msg" >/dev/null 2>&1 || \
    logger -t silent-hang-monitor "WARN: Telegram notification failed" || true
  echo "$now" > "$cooldown_file"
}

gateway_status_text="$("$OPENCLAW_BIN" gateway status 2>/dev/null || true)"
channels_status_text="$("$OPENCLAW_BIN" channels status --probe 2>/dev/null || true)"

gateway_ok="false"
if grep -q 'Runtime: running' <<<"$gateway_status_text" && grep -q 'RPC probe: ok' <<<"$gateway_status_text"; then
  gateway_ok="true"
fi

channels_ok="true"
channels_warn_reason=""
if grep -Eqi 'pairing required|blocked|allowlist|mention required|failed|error|unauthorized' <<<"$channels_status_text"; then
  channels_ok="false"
  channels_warn_reason="$(grep -Ei 'pairing required|blocked|allowlist|mention required|failed|error|unauthorized' <<<"$channels_status_text" | head -1 | tr -d '\r' | python3 -c "import sys; print(sys.stdin.read()[:80])")"
fi

session_stats="$(
SESSION_DIR="$SESSION_DIR" WEB_WINDOW_SEC="$WEB_WINDOW_SEC" python3 - <<'PY'
import json, os, sys
from pathlib import Path
from datetime import datetime, timezone

session_dir = Path(os.environ["SESSION_DIR"])
web_window = int(os.environ["WEB_WINDOW_SEC"])

def parse_ts(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        if value > 1e12:
            value = value / 1000.0
        return float(value)
    if not isinstance(value, str):
        return None
    s = value.strip()
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        try:
            v = float(s)
            if v > 1e12:
                v = v / 1000.0
            return v
        except Exception:
            return None

def pick_ts(obj):
    for key in ("ts", "timestamp", "createdAt", "time", "date"):
        if isinstance(obj, dict) and key in obj:
            parsed = parse_ts(obj.get(key))
            if parsed is not None:
                return parsed
    return None

files = sorted(session_dir.glob("*.jsonl"), key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)
now = datetime.now(timezone.utc).timestamp()

payload = {
    "session_file": "",
    "last_user_ts": None,
    "last_assistant_ts": None,
    "last_user_age_sec": None,
    "last_assistant_age_sec": None,
    "pending_age_sec": None,
    "recent_web_calls": 0,
}

if not files:
    print(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0)

session_file = files[0]
payload["session_file"] = str(session_file)
last_user = None
last_assistant = None
recent_web = 0

for line in session_file.read_text(encoding="utf-8", errors="ignore").splitlines():
    line_l = line.lower()
    try:
        obj = json.loads(line)
    except Exception:
        obj = {}
    stamp = pick_ts(obj)
    if stamp is None:
        continue

    if '"role":"user"' in line_l or '"author":"user"' in line_l or '"sender":"user"' in line_l:
        last_user = max(last_user or 0, stamp)
    if '"role":"assistant"' in line_l or '"author":"assistant"' in line_l or '"sender":"assistant"' in line_l:
        last_assistant = max(last_assistant or 0, stamp)
    if 'web_search' in line_l or 'web_fetch' in line_l:
        if now - stamp <= web_window:
            recent_web += 1

payload["last_user_ts"] = last_user
payload["last_assistant_ts"] = last_assistant
payload["last_user_age_sec"] = None if last_user is None else int(now - last_user)
payload["last_assistant_age_sec"] = None if last_assistant is None else int(now - last_assistant)
if last_user is not None and (last_assistant is None or last_user > last_assistant):
    payload["pending_age_sec"] = int(now - last_user)
payload["recent_web_calls"] = recent_web

print(json.dumps(payload, ensure_ascii=False))
PY
)"

last_user_age="$(python3 -c "import json,sys; v=json.loads(sys.argv[1]).get('last_user_age_sec'); print('' if v is None else v)" "$session_stats")"
pending_age="$(python3 -c "import json,sys; v=json.loads(sys.argv[1]).get('pending_age_sec'); print('' if v is None else v)" "$session_stats")"
recent_web_calls="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('recent_web_calls',0))" "$session_stats")"

hour_now="$(TZ=Asia/Tokyo date '+%-H')"
quiet_now="false"
if [ "$hour_now" -ge "$QUIET_START_HOUR" ] && [ "$hour_now" -lt "$QUIET_END_HOUR" ]; then
  quiet_now="true"
fi

minute_now="$(TZ=Asia/Tokyo date '+%-M')"
if [[ "${SAMPLE_EVERY_MIN:-5}" -gt 0 ]] && [ $((minute_now % SAMPLE_EVERY_MIN)) -eq 0 ]; then
  emit_event "silent_hang_sample" "info" "observe" "sample collected" \
    "$(python3 -c "
import json,sys
print(json.dumps({
    'gateway_ok': sys.argv[1]=='true',
    'channels_ok': sys.argv[2]=='true',
    'channels_reason': sys.argv[3],
    'session': json.loads(sys.argv[4])
}, ensure_ascii=False))
" "$gateway_ok" "$channels_ok" "$channels_warn_reason" "$session_stats")"
fi

if [ "$gateway_ok" != "true" ]; then
  emit_event "gateway_rpc_unhealthy" "critical" "notify" \
    "gateway status is not healthy" \
    "$(python3 -c "import json,sys; print(json.dumps({'gateway_status':sys.argv[1][:800]},ensure_ascii=False))" "$gateway_status_text")"
  notify "🚨 Gateway異常" "gateway_unhealthy
$(ts_jst_hm) gateway status が unhealthy
次: openclaw gateway status / openclaw logs --follow を確認"
fi

if [ "$channels_ok" != "true" ]; then
  emit_event "channel_probe_warn" "warn" "notify" \
    "channels status probe reported a warning" \
    "$(python3 -c "import json,sys; print(json.dumps({'probe_reason':sys.argv[1]},ensure_ascii=False))" "$channels_warn_reason")"
  notify "⚠️ Channel警告
$(ts_jst_hm) channels status --probe に警告
内容: ${channels_warn_reason:-unknown}" "channel_warn"
fi

if [ -n "${pending_age:-}" ] && [ "$quiet_now" != "true" ]; then
  if [ "${last_user_age:-999999}" -le "$ACTIVE_WINDOW_SEC" ] && [ "$pending_age" -ge "$REPLY_AGE_SEC" ] && [ "$gateway_ok" = "true" ]; then
    emit_event "silent_hang_suspected" "critical" "notify" \
      "recent user input exists but assistant reply is stale" \
      "$(python3 -c "import json,sys; p=json.loads(sys.argv[1]); p['gateway_ok']=(sys.argv[2]=='true'); p['channels_ok']=(sys.argv[3]=='true'); print(json.dumps(p,ensure_ascii=False))" "$session_stats" "$gateway_ok" "$channels_ok")"
    notify "🚨 無言停止の疑い
$(ts_jst_hm) 直近の入力に返答がありません
pending_age=${pending_age}s
次: openclaw gateway status / channels status --probe / 最新session確認" "silent_hang"
  fi
fi

if [ "${recent_web_calls:-0}" -ge "$WEB_BURST_THRESHOLD" ]; then
  emit_event "web_concurrency_burst" "high" "notify" \
    "recent session shows burst of web_search/web_fetch calls" \
    "$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]),ensure_ascii=False))" "$session_stats")"
  notify "⚠️ web同時実行の疑い
$(ts_jst_hm) recent_web_calls=${recent_web_calls}
次: AGENTS運用ルールとsessionログ確認" "web_burst"
fi
