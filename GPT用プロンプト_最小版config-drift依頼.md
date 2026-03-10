# GPT-5.4への依頼 — config-drift-check.sh 最小版 + Phase 1実行プラン

## 状況

返信08の方針転換に同意。Phase 1を以下に圧縮します：

1. OpenClaw本体設定（即適用）
2. 危険cron整理（即実行 — **watchdog導入より先にやる。restart主体を減らしてから増やす**）
3. 公式watchdog skill（コードレビュー後に導入）
4. config-drift-check.sh 最小版（自作はこれ1本だけ）

### ロブ側で確認済みの追加事実

- **Issue #30183（bonjour watchdog無限ループ）**: WSL2環境で24時間分のjournalにbonjourログゼロ。WSL2ではbonjourサービスが動いていないため未発生。導入OK
- **`openclaw config validate --json`の出力**: `{"valid":true,"path":"/home/yama/.openclaw/openclaw.json"}`（キーは`valid`）
- **既存restart主体の現状**: cron（正午restart）+ systemd（Restart=on-failure）+ ロブ手動の3者。watchdog導入前に**cronのrestart系を先に止める**のが必須（port競合763回の教訓）

## 依頼

### 1. config-drift-check.sh 最小版（80-140行目標）

前回版（489行）から以下だけ残してください：

**やること:**
- `/home/yama/.openclaw/openclaw.json` の sha256sum
- `/home/yama/ws/state/rob-ops/known-good/openclaw.json` と比較
- `openclaw config validate --json`（出力は `{"valid":true}` 形式）
- dangerous_config_keys 20キーだけ JSON diff
- drift検知時は Telegram通知（`openclaw message send`経由）
- events.jsonl に1行出力（Phase 3への布石。schemaは返信06のemit_eventと同じフォーマット）

**やらないこと:**
- human log（Phase 3で足す）
- state管理のdedupe/cooldown（cronの1分間隔で十分）
- rollback
- restart request file（config-driftはrestartしない。責務分離）
- common.sh（1本だけなので不要）

**環境情報:**
- OpenClaw: 2026.3.2 / WSL2 Ubuntu / Node v22.22.0
- binary: `/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw`
- config: `/home/yama/.openclaw/openclaw.json`
- known-good: `/home/yama/ws/state/rob-ops/known-good/openclaw.json`
- events.jsonl: `/home/yama/ws/logs/rob-ops/events.jsonl`
- Telegram: `openclaw message send --channel "telegram:pairing" --text "..."`

### 2. systemd timer 1本

config-drift-check.sh を毎分実行する timer/service ペア。

### 3. Phase 1 実行チェックリスト

やまちゃん🗻とロブ🦞が「これを上から順にやれば完了」となる手順書。
各ステップに含めるもの：
- 誰がやるか（🦞ロブ / 🗻やまちゃん）
- コマンド（コピペで実行できる形）
- 確認方法
- ロールバック方法

**実行順序の制約:**
- Phase 1-2（cron整理）を Phase 1-3（watchdog導入）より**必ず先に**やること
- restart主体を減らしてから増やす（port競合763回の教訓）

### 4. watchdog skill レビューチェックリスト

SKILL.mdと実スクリプトを読む時のチェック8項目：
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

- restart-arbiter.shは作らない（watchdog skillに任せる）
- common.shは作らない（1本だけ）
- openclaw-monitor.sh / rob-health-monitor.sh は作らない（watchdogで代替）
- config-drift-checkは**restartしない**（責務分離: 壊れたら知らせるだけ）
- Phase 3のゴール（しゃべるシステム、RUNBOOK、ops digest）はevents.jsonl 1行出力で布石だけ打つ

## 出力してほしいもの

1. `config-drift-check.sh` 最小版（全文、80-140行）
2. `rob-config-drift.service` + `rob-config-drift.timer`
3. Phase 1実行チェックリスト
4. watchdog skillレビューチェックリスト
