# GPT-5.4への依頼 — config-drift-check.sh 最小版 + Phase 1実行プラン

## 状況

返信08の方針転換に完全同意します。Phase 1を以下に圧縮します：

1. OpenClaw本体設定（即適用）
2. 危険cron整理（即実行）
3. 公式watchdog skill（コードレビュー後に導入）
4. **config-drift-check.sh 最小版（自作はこれ1本だけ）**

## 依頼

### 1. config-drift-check.sh 最小版（80-140行目標）

前回版（489行）から以下だけ残してください：

**やること:**
- `/home/yama/.openclaw/openclaw.json` の sha256sum
- `/home/yama/ws/state/rob-ops/known-good/openclaw.json` と比較
- `openclaw config validate --json`（出力は `{"valid":true}` 形式）
- dangerous_config_keys 20キーだけ JSON diff
- drift検知時は Telegram通知（`openclaw message send`経由）
- events.jsonl に1行出力（Phase 3への布石）

**やらないこと:**
- human log（Phase 3で足す）
- state管理のdedupe/cooldown（cronの1分間隔で十分。同じdriftを毎分通知しても1分に1回なら許容範囲）
- rollback
- restart request file
- common.sh（1本だけなので不要）

**環境情報:**
- OpenClaw: 2026.3.2
- binary: `/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw`
- config: `/home/yama/.openclaw/openclaw.json`
- known-good: `/home/yama/ws/state/rob-ops/known-good/openclaw.json`
- events.jsonl: `/home/yama/ws/logs/rob-ops/events.jsonl`
- Telegram送信先: `telegram:pairing`（`openclaw message send --channel telegram:pairing --text "..."` で送れる）
- `openclaw config validate --json` の出力: `{"valid":true,"path":"..."}`

### 2. systemd timer 1本

config-drift-check.sh を毎分実行する timer/service ペア。

### 3. Phase 1 実行チェックリスト

やまちゃん🗻とロブ🦞が「これを上から順にやれば完了」となる手順書。
各ステップに以下を含めてください：
- 誰がやるか（🦞ロブ / 🗻やまちゃん）
- コマンド（コピペで実行できる形）
- 確認方法
- ロールバック方法

### 4. watchdog skill導入のレビューチェックリスト

SKILL.mdと実スクリプトを読む時に、何を確認すべきかのチェックリスト。
返信08で挙げた8項目を整理してください：
- restart条件
- backoff実装
- systemdをどう触るか
- bonjour watchdogを使うか
- Telegram通知先
- custom recovery scriptの実行条件
- configを勝手に書き換えないか
- 危険コマンドの有無

---

## 注意事項

- **restart-arbiter.shは作らない**（watchdog skillに任せる）
- **common.shは作らない**（1本だけなので不要）
- **openclaw-monitor.sh / rob-health-monitor.sh は作らない**（watchdog skillで代替）
- Phase 3のゴール（しゃべるシステム、RUNBOOK、ops digest）はevents.jsonl 1行出力で布石だけ打つ

## 出力してほしいもの

1. `config-drift-check.sh` 最小版（全文、80-140行）
2. `systemd/user/rob-config-drift.service` + `rob-config-drift.timer`
3. Phase 1実行チェックリスト
4. watchdog skillレビューチェックリスト
