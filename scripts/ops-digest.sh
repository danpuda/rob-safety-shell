#!/bin/bash
# ops-digest.sh — Phase 3: 自己説明システム
# モード: human(JSONL→日本語変換) / digest(日次サマリ) / runbook(RUNBOOK.md生成) / all
# 設計: GPT-5.4 返信10
set -euo pipefail
trap 'on_error ${LINENO}' ERR

LOCK_FILE="${LOCK_FILE:-/tmp/ops-digest.lock}"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

MODE="${1:-human}"

OPENCLAW_BIN="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null)}"
: "${OPENCLAW_BIN:?openclaw binary not found in PATH, set OPENCLAW_BIN}"
STATE_DIR="${STATE_DIR:-$HOME/ws/state/rob-ops}"
LOG_DIR="${LOG_DIR:-$HOME/ws/logs/rob-ops}"
EVENTS_JSONL="${EVENTS_JSONL:-$LOG_DIR/events.jsonl}"
HUMAN_LOG="${HUMAN_LOG:-$LOG_DIR/events-human.log}"
HUMAN_STATE="${HUMAN_STATE:-$STATE_DIR/human-log.state}"
RUNBOOK_PATH="${RUNBOOK_PATH:-$HOME/ws/RUNBOOK.md}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:?TELEGRAM_TARGET must be set}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

ts_iso() { date --iso-8601=seconds; }

on_error() {
  local line="$1"
  EVENT_TS="$(ts_iso)" EVENTS_PATH="$EVENTS_JSONL" LINE_NO="$line" python3 - <<'PY'
import json, os
from pathlib import Path
payload = {
    "ts": os.environ["EVENT_TS"],
    "layer": "reporter",
    "component": "ops-digest",
    "event": "ops_digest_error",
    "severity": "critical",
    "decision": "notify",
    "reason": f"ops-digest failed at line {os.environ['LINE_NO']}",
    "target": os.environ["EVENTS_PATH"],
    "next_step": "inspect ops-digest.sh",
    "evidence": {"line": int(os.environ["LINE_NO"])},
}
path = Path(os.environ["EVENTS_PATH"])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(payload, ensure_ascii=False) + "\n")
PY
}

send_telegram() {
  local msg="$1"
  "$OPENCLAW_BIN" message send --channel telegram --target "$TELEGRAM_TARGET" -m "$msg" >/dev/null 2>&1 || \
    logger -t ops-digest "WARN: Telegram notification failed" || true
}

render_human() {
  [[ -f "$EVENTS_JSONL" ]] || exit 0
  [[ -f "$HUMAN_STATE" ]] || echo "0" > "$HUMAN_STATE"
  local start_line
  start_line="$(cat "$HUMAN_STATE" 2>/dev/null || echo 0)"
  python3 - <<'PY' "$EVENTS_JSONL" "$HUMAN_LOG" "$HUMAN_STATE" "$start_line"
import json, sys
from pathlib import Path
from datetime import datetime

events_path = Path(sys.argv[1])
human_path = Path(sys.argv[2])
state_path = Path(sys.argv[3])
start_line = int(sys.argv[4])

lines = events_path.read_text(encoding="utf-8", errors="ignore").splitlines()
new = lines[start_line:]

def hm(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z","+00:00")).astimezone().strftime("%H:%M")
    except Exception:
        return "??:??"

def humanize(ev):
    ts = hm(ev.get("ts",""))
    name = ev.get("event","unknown")
    sev = ev.get("severity","info")
    evidence = ev.get("evidence", {})
    if name == "config_drift_detected":
        keys = evidence.get("dangerousChangeCount") or len(evidence.get("dangerousDiff", []))
        return f"{ts} 🚨 config改ざん検知: 危険変更 {keys} 件"
    if name == "gateway_rpc_unhealthy":
        return f"{ts} 🚨 Gateway異常: RPC probe が unhealthy"
    if name == "channel_probe_warn":
        return f"{ts} ⚠️ Channel警告: {evidence.get('probe_reason','詳細不明')}"
    if name == "silent_hang_suspected":
        return f"{ts} 🚨 無言停止の疑い: 入力後に返答が止まっている"
    if name == "web_concurrency_burst":
        return f"{ts} ⚠️ web同時実行多発: recent_web_calls={evidence.get('recent_web_calls','?')}"
    if name == "silent_hang_sample":
        g = evidence.get("gateway_ok")
        c = evidence.get("channels_ok")
        icon = "✅" if g and c else "⚠️"
        return f"{ts} {icon} Gatewayサンプル: gateway_ok={g} channels_ok={c}"
    if name == "ops_digest_error":
        return f"{ts} 🚨 digestエラー"
    icon = {"critical":"🚨","high":"⚠️","warn":"⚠️","info":"✅"}.get(sev,"ℹ️")
    return f"{ts} {icon} {name}: {ev.get('reason','')}"

out = []
for line in new:
    if not line.strip():
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    out.append(humanize(ev))

if out:
    with human_path.open("a", encoding="utf-8") as f:
        for row in out:
            f.write(row + "\n")
state_path.write_text(str(len(lines)), encoding="utf-8")
PY
}

daily_digest() {
  [[ -f "$EVENTS_JSONL" ]] || exit 0
  local digest
  digest="$(python3 - <<'PY' "$EVENTS_JSONL"
import json, sys
from pathlib import Path
from datetime import datetime

events = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").splitlines():
    if not line.strip():
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    events.append(ev)

today = datetime.now().astimezone().date()
today_events = []
for ev in events:
    try:
        dt = datetime.fromisoformat(ev["ts"].replace("Z","+00:00")).astimezone()
    except Exception:
        continue
    if dt.date() == today:
        today_events.append((dt, ev))

crit = [ev for _, ev in today_events if ev.get("severity") == "critical"]
high = [ev for _, ev in today_events if ev.get("severity") == "high"]
warn = [ev for _, ev in today_events if ev.get("severity") == "warn"]
cfg = [ev for _, ev in today_events if ev.get("event") == "config_drift_detected"]
samples = [ev for _, ev in today_events if ev.get("event") == "silent_hang_sample"]

uptime = "n/a"
if samples:
    ok = sum(1 for ev in samples if ev.get("evidence",{}).get("gateway_ok") is True and ev.get("evidence",{}).get("channels_ok") is True)
    uptime = f"{round(ok*100/len(samples))}%"

major = []
for dt, ev in today_events:
    if ev.get("severity") in ("critical", "high"):
        major.append(f"{dt.strftime('%H:%M')} {ev.get('event')}")

# cause-chain: 10分以内の重大イベント連鎖
chains = []
window = []
for dt, ev in today_events:
    if ev.get("severity") not in ("critical", "high"):
        continue
    if not window:
        window = [(dt, ev)]
        continue
    if (dt - window[-1][0]).total_seconds() <= 600:
        window.append((dt, ev))
    else:
        if len(window) >= 2:
            chains.append(" → ".join(x[1].get("event","?") for x in window[:4]))
        window = [(dt, ev)]
if len(window) >= 2:
    chains.append(" → ".join(x[1].get("event","?") for x in window[:4]))

lines = ["📘 Daily Ops Digest"]
if not today_events:
    lines.append("今日は events.jsonl にイベントなし")
else:
    if not crit and not high:
        lines.append("今日は大きな障害なし ✅")
    else:
        lines.append(f"障害: critical={len(crit)} / high={len(high)} / warn={len(warn)}")
    lines.append(f"Gateway観測稼働率: {uptime}")
    lines.append(f"config変更検知: {len(cfg)}件")
    if major:
        lines.append("主な出来事:")
        lines.extend(f"- {x}" for x in major[:3])
    if chains:
        lines.append("原因連鎖:")
        lines.append(f"- {chains[0]}")

print("\n".join(lines[:10]))
PY
)"
  send_telegram "$digest"
}

generate_runbook() {
  cat > "$RUNBOOK_PATH" <<'EOF'
# RUNBOOK.md

このファイルは「やまちゃん🗻がすぐ読むための障害手順書」です。
難しい単語を避けて、やることを順番に書きます。

## config_drift_detected
何が起きた:
- openclaw.json が変わった

確認すること:
1. `git diff ~/.openclaw/openclaw.json`
2. `openclaw config validate --json`

対処法:
- 意図した変更なら known-good を更新: `cp ~/.openclaw/openclaw.json ~/ws/state/rob-ops/known-good/`
- 意図しない変更なら元に戻す: `cp ~/ws/state/rob-ops/known-good/openclaw.json ~/.openclaw/`

## gateway_rpc_unhealthy
何が起きた:
- Gateway は動いているように見えるが、中の通信(RPC)がおかしい

確認すること:
1. `openclaw gateway status`
2. `openclaw doctor`

対処法:
- `openclaw gateway stop` → 3秒待つ → `openclaw gateway start`
- それでもダメなら: `journalctl --user -u openclaw-gateway -n 50` でログを見る

## channel_probe_warn
何が起きた:
- Telegram等のチャンネル接続に問題がある

確認すること:
1. `openclaw channels status --probe`

対処法:
- "pairing required" → Telegramでボットに /start を送る
- "blocked" → ボットがブロックされてないか確認
- "error" → gateway再起動を試す

## silent_hang_suspected
何が起きた:
- やまちゃんがメッセージを送ったのに、ロブが返事しない

確認すること:
1. `openclaw gateway status` → "Runtime: running" か？
2. `openclaw channels status --probe` → "works" か？
3. Telegramでもう一度メッセージを送ってみる

対処法:
- Gateway正常なのに返事ない → セッションが詰まってる可能性
- `openclaw gateway stop` → `openclaw gateway start` で復旧

## web_concurrency_burst
何が起きた:
- ロブがweb検索を短時間に何回もやって、Gatewayが不安定になるリスクがある

確認すること:
1. 特に何もしなくてOK（通知だけ）

対処法:
- ロブに「web検索を1個ずつやって」と伝える
- 頻発するならAGENTS.mdのルールを強化
EOF
}

case "$MODE" in
  human)
    render_human
    ;;
  digest)
    daily_digest
    ;;
  runbook)
    generate_runbook
    ;;
  all)
    render_human
    daily_digest
    generate_runbook
    ;;
  *)
    echo "usage: $0 {human|digest|runbook|all}" >&2
    exit 1
    ;;
esac
