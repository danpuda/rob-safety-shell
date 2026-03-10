# Rob Safety Shell — 全体アクションプラン
> 最終更新: 2026-03-11 02:57 JST

## 📊 プロジェクト全体像

### 開発:テスト比率 = 5:95
```
コード書く    █░░░░░░░░░░░░░░░░░░░   5%（もう終わってる）
手動テスト    █░░░░░░░░░░░░░░░░░░░   5%（数コマンド）
レビュー読む  ███░░░░░░░░░░░░░░░░░░  15%（watchdog確認）
放置して待つ  ███████████████░░░░░░  75%（shadow観察）
```

### 全Phase進捗
```
Phase 1 設計・コード  ████████████████████  100%（完了）
Phase 1 デプロイ      ░░░░░░░░░░░░░░░░░░░░    0%（次やる）
Phase 2               ░░░░░░░░░░░░░░░░░░░░    0%
Phase 3               █░░░░░░░░░░░░░░░░░░░    2%（JSONL布石のみ）
─────────────────────────────────────────────
全体                  █████░░░░░░░░░░░░░░░░   25%
```

---

## ⏱️ スケジュール（修正版 — elvis-loop前提）

```
3/11  Phase 1 Step 1-4 デプロイ+テスト（実作業40分）
3/11  Phase 1 Step 5 watchdogレビュー（30分）
3/11  Phase 1 Step 6 watchdog staging + shadow開始
3/12  Phase 1 24h shadow完了 → Step 7 本番化 → Phase 1完了 ✅
3/12  Phase 2 GPT-5.4に設計依頼（shadow待ち中に並行）
3/13  Phase 2 elvis-loop実装+FL3（実作業4h）
3/14  Phase 2 デプロイ → 観察開始
3/14  Phase 3 GPT-5.4に設計依頼（並行）
3/15  Phase 3 elvis-loop実装+FL3（実作業4h）
3/16  Phase 3 デプロイ → 観察開始
3/17  全Phase完了 ✅（観察は継続）
```

**実作業合計: 約9時間 / カレンダー上: 6日（shadow待ちが大半）**

---

## 📋 Phase 1 アクションプラン（次やること）

### Step 1: 本体設定hardening 🦞ロブ（5分）
```bash
# バックアップ
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak.$(date +%Y%m%d-%H%M%S)

# agents.list に group:automation deny 追加
# tools.elevated.enabled: false 確認
openclaw config validate --json
openclaw security audit --json || true
```
- ✅条件: `{"valid":true}` + audit致命的警告なし
- 🔙ロールバック: `cp .bak ~/.openclaw/openclaw.json`

### Step 2: 危険cron整理 🗻やまちゃん（3分）
```bash
crontab -l > ~/ws/backup/crontab.before.phase1.$(date +%Y%m%d-%H%M%S)
crontab -e  # 正午restart cron削除/コメントアウト
```
- ✅条件: `crontab -l` にrestart直叩きcronが0件
- 🔙ロールバック: `crontab ~/ws/backup/crontab.before.phase1.*`

### Step 3: config-drift-check.sh 単体テスト 🦞ロブ（10分）
```bash
# 配置
mkdir -p ~/ws/scripts ~/ws/state/rob-ops/known-good ~/ws/logs/rob-ops
cp ~/ws/phase1-impl/scripts/config-drift-check.sh ~/ws/scripts/
chmod +x ~/ws/scripts/config-drift-check.sh

# known-good初期化（手動必須 — H-2修正で自動化を削除済み）
cp ~/.openclaw/openclaw.json ~/ws/state/rob-ops/known-good/openclaw.json

# 正常系: driftなし → 静か
bash ~/ws/scripts/config-drift-check.sh && echo "exit: $?"
cat ~/ws/logs/rob-ops/events.jsonl  # 空 or なし

# 異常系: driftあり → Telegram通知来る
cp ~/.openclaw/openclaw.json /tmp/test-good.json
python3 -c "import json; c=json.load(open('/tmp/test-good.json')); c['tools']={'elevated':{'enabled':True}}; json.dump(c,open('/tmp/test-bad.json','w'))"
CONFIG_PATH=/tmp/test-bad.json KNOWN_GOOD_PATH=/tmp/test-good.json \
  bash ~/ws/scripts/config-drift-check.sh
# → Telegram通知 + events.jsonl 1行
```
- ✅条件: 正常系=静か、異常系=通知+JSONL出力
- 🔙ロールバック: `rm ~/ws/scripts/config-drift-check.sh`

### Step 4: systemd timer shadow 🦞ロブ（20分 — 15分は放置）
```bash
cp ~/ws/phase1-impl/systemd/user/rob-config-drift.service ~/.config/systemd/user/
cp ~/ws/phase1-impl/systemd/user/rob-config-drift.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now rob-config-drift.timer
systemctl --user list-timers | grep rob-config-drift
# 15分放置
journalctl --user -u rob-config-drift.service --since "-15 min" --no-pager
```
- ✅条件: 毎分実行、エラーなし、drift時のみ通知
- 🔙ロールバック: `systemctl --user disable --now rob-config-drift.timer`

### Step 5: watchdog skillレビュー 🦞ロブ（30分）
```bash
npx clawhub@latest install openclaw-watchdog --dry-run
# → SKILL.md + 実スクリプトを読む
```
8項目チェック:
- [ ] restart条件（何をもって死んだと判定？）
- [ ] backoff（cooldown/exponential/max retry）
- [ ] systemdの触り方（systemctl restart? openclaw gateway start?）
- [ ] bonjour watchdog使うか（Issue #30183直撃）
- [ ] Telegram通知先
- [ ] custom recovery scriptの実行条件
- [ ] configを勝手に書き換えないか
- [ ] 危険コマンド（pkill -f, kill -9, rm -rf等）

### Step 6: watchdog staging 🦞ロブ（24h放置）
- notification-only or dry-runで入れる
- bonjour loop監視: `journalctl --user | grep -i bonjour`
- 11秒周期restart監視

### Step 7: watchdog本番化 🦞ロブ + 🗻やまちゃん（10分）
- restart系cronが消えてること最終確認
- watchdog有効化

### Phase 1完了条件
- [ ] restart主体が整理されている（systemd + watchdog の2層のみ）
- [ ] watchdogがcrashを拾える
- [ ] config driftが1分以内に見える
- [ ] false positiveが許容範囲
- [ ] 正午restart cronが消えている
- [ ] 24h shadow問題なし

---

## 📋 Phase 2 アクションプラン: 黙らない

| # | タスク | 担当 | 実作業 |
|---|--------|------|--------|
| 1 | GPT-5.4に設計依頼（probe + reply-age） | 😎GPT | 30分 |
| 2 | GPT返信レビュー + ファクトチェック | 🦞ロブ | 30分 |
| 3 | elvis-loop: コード実装+FL3 | 🤓Codex+@claude | 2h |
| 4 | 並列HTTP制限（OpenClaw設定 or 自作） | 🦞ロブ | 30分 |
| 5 | デプロイ + テスト | 🦞ロブ | 30分 |
| 6 | 観察（放置） | - | 数日 |

## 📋 Phase 3 アクションプラン: 自己説明できる

| # | タスク | 担当 | 実作業 |
|---|--------|------|--------|
| 1 | GPT-5.4に設計依頼（JSONL + digest + RUNBOOK） | 😎GPT | 30分 |
| 2 | GPT返信レビュー | 🦞ロブ | 30分 |
| 3 | elvis-loop: JSONL統一+human log+cause-chain | 🤓Codex+@claude | 2h |
| 4 | elvis-loop: daily ops digest+RUNBOOK | 🤓Codex+@claude | 2h |
| 5 | デプロイ + テスト | 🦞ロブ | 30分 |
| 6 | 観察（放置） | - | 数日 |

---

## 🏆 完了条件（全Phase）

### Phase 1: 死なない ✅
- config変更が1分以内に検知・通知される
- Gateway crash時にwatchdogが自動復旧する
- restart主体が整理されている

### Phase 2: 黙らない
- alive but unusableを検知できる
- 無言停止をreply-ageで拾える
- 並列HTTP暴走が抑制される

### Phase 3: 自己説明できる
- 何が起きたか1行で読める
- 日次で「平和だった / N回火事があった」が届く
- GPT-3.5でも追えるRUNBOOKがある
