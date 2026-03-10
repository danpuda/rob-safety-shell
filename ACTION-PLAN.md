# Rob Safety Shell — 全体アクションプラン

## 📊 進捗率

### Phase 1: 死なない（目標: 2-3日）

| タスク | 状態 | 進捗 |
|--------|------|------|
| インシデントDB (29件) | ✅ 完了 | 100% |
| GPT-5.4 要件定義・設計 (返信01-09) | ✅ 完了 | 100% |
| 既存ツール調査 (5ツール) | ✅ 完了 | 100% |
| 方針転換 → 最小構成決定 | ✅ 完了 | 100% |
| config-drift-check.sh コーディング | ✅ 完了 | 100% |
| FL3 Round 1 (Codex+Sonnet) | ✅ 完了 | 100% |
| FL3指摘修正 (CRITICAL 2 + HIGH 4) | ✅ 完了 | 100% |
| FL3 Round 2 (Codex 82/100) | ✅ 完了 | 100% |
| P1バグ修正 (env export) | ✅ 完了 | 100% |
| systemd timer 作成 | ✅ 完了 | 100% |
| **Step 1: 本体設定hardening** | ⬜ 未着手 | 0% |
| **Step 2: 危険cron整理** | ⬜ 未着手 | 0% |
| **Step 3: config-drift単体テスト** | ⬜ 未着手 | 0% |
| **Step 4: timer shadow 10-15分** | ⬜ 未着手 | 0% |
| **Step 5: watchdog skillレビュー** | ⬜ 未着手 | 0% |
| **Step 6: watchdog staging検証** | ⬜ 未着手 | 0% |
| **Step 7: watchdog本番有効化** | ⬜ 未着手 | 0% |
| known-good初期化 | ⬜ 未着手 | 0% |
| 24時間shadow観察 | ⬜ 未着手 | 0% |

**Phase 1 進捗: 約55%（設計・コード完了、デプロイ・テスト未着手）**

### Phase 2: 黙らない（目標: 1週間）
| タスク | 状態 | 進捗 |
|--------|------|------|
| synthetic probe設計 | ⬜ | 0% |
| reply-age / session freshness | ⬜ | 0% |
| 並列外部HTTP制限 | ⬜ | 0% |
| timeout/overloaded閾値 | ⬜ | 0% |

**Phase 2 進捗: 0%**

### Phase 3: 自己説明できる（目標: 2週間）
| タスク | 状態 | 進捗 |
|--------|------|------|
| JSONL統一ログ | 🟡 布石あり | 10% |
| human-readable log | ⬜ | 0% |
| cause-chain | ⬜ | 0% |
| daily ops digest | ⬜ | 0% |
| RUNBOOK.md | ⬜ | 0% |
| incident report自動生成 | ⬜ | 0% |

**Phase 3 進捗: ~2%（JSONL schemaの思想だけ）**

---

## 🎯 全体進捗: **約25%**

```
設計・コード  ████████████████░░░░  80%
テスト・検証  ██░░░░░░░░░░░░░░░░░░  10%
デプロイ      ░░░░░░░░░░░░░░░░░░░░   0%
Phase 2-3     ░░░░░░░░░░░░░░░░░░░░   1%
─────────────────────────────────────
全体          █████░░░░░░░░░░░░░░░░  25%
```

---

## 📋 残りアクションプラン（実行順）

### 🔥 即実行可能（Phase 1 デプロイ）

#### Step 1: 本体設定hardening 🦞ロブ
```bash
# バックアップ
cp /home/yama/.openclaw/openclaw.json /home/yama/.openclaw/openclaw.json.bak.$(date +%Y%m%d-%H%M%S)

# agents.list に group:automation deny 追加
# tools.elevated.enabled: false 確認
# openclaw config validate --json で確認
# openclaw security audit 実行
```
- 確認: `{"valid":true}` + audit結果レビュー
- ETA: 5分

#### Step 2: 危険cron整理 🗻やまちゃん
```bash
crontab -l > ~/ws/backup/crontab.before.phase1.$(date +%Y%m%d-%H%M%S)
crontab -e  # 正午restart cron削除
```
- 確認: `crontab -l` でrestart系cron消えてること
- ETA: 3分

#### Step 3: config-drift-check.sh 単体テスト 🦞ロブ
```bash
# スクリプト配置
mkdir -p ~/ws/scripts ~/ws/state/rob-ops/known-good ~/ws/logs/rob-ops
cp ~/ws/phase1-impl/scripts/config-drift-check.sh ~/ws/scripts/
chmod +x ~/ws/scripts/config-drift-check.sh

# known-good初期化（手動必須）
cp ~/.openclaw/openclaw.json ~/ws/state/rob-ops/known-good/openclaw.json

# 正常系テスト（drift なし→静か）
bash ~/ws/scripts/config-drift-check.sh
echo $?  # 0であること
cat ~/ws/logs/rob-ops/events.jsonl  # 空であること

# 異常系テスト（drift あり→通知来る）
echo '{}' > /tmp/test-config.json
# CONFIG_PATH=/tmp/test-config.json で実行して通知来るか確認
```
- 確認: Telegram通知 + events.jsonl 1行
- ETA: 10分

#### Step 4: timer shadow 10-15分 🦞ロブ
```bash
mkdir -p ~/.config/systemd/user
cp ~/ws/phase1-impl/systemd/user/rob-config-drift.service ~/.config/systemd/user/
cp ~/ws/phase1-impl/systemd/user/rob-config-drift.timer ~/.config/systemd/user/
# serviceのExecStartパスを実際のパスに修正
systemctl --user daemon-reload
systemctl --user enable --now rob-config-drift.timer
systemctl --user list-timers | grep rob-config-drift
```
- 確認: 15分間無限エラーしない、drift時だけ通知
- ETA: 20分（待ち時間含む）

#### Step 5: watchdog skillレビュー 🦞ロブ + 😎GPT
```bash
npx clawhub@latest install openclaw-watchdog --dry-run  # まだ入れない
# SKILL.md + 実スクリプトを読む
# 8項目チェックリスト埋める
```
- 確認: 8項目全てOK
- ETA: 30分

#### Step 6: watchdog staging 🦞ロブ
- notification-only / dry-runモードで検証
- bonjour loop確認（WSL2なので出ないはず）
- 24時間shadow
- ETA: 24時間

#### Step 7: watchdog本番有効化 🦞ロブ + 🗻やまちゃん
- restart系cronが消えてること最終確認
- watchdog有効化
- ETA: 10分

### ✅ Phase 1完了条件
- [ ] restart を勝手に叩く主体が整理されている
- [ ] watchdog が crash を拾える
- [ ] config drift が 1分以内に見える
- [ ] false positive が許容範囲
- [ ] 正午 restart cron が消えている
- [ ] 24時間shadow問題なし

---

### 🔮 Phase 2: 黙らない（Phase 1完了後）

| # | タスク | 担当 | ETA |
|---|--------|------|-----|
| 1 | synthetic probe設計 → GPT-5.4に依頼 | 😎GPT | 1日 |
| 2 | reply-age検知実装 | 😎GPT→🤓Codex | 1日 |
| 3 | 並列外部HTTP制限（web_search/fetch同時2個制限） | 🦞ロブ | 半日 |
| 4 | timeout/overloaded閾値調整 | 🦞ロブ | 半日 |
| 5 | FL3レビュー | 🤓Codex + 🟠Sonnet | 半日 |
| 6 | デプロイ + 1週間観察 | 🦞ロブ | 1週間 |

### 🔮 Phase 3: 自己説明できる（Phase 2完了後）

| # | タスク | 担当 | ETA |
|---|--------|------|-----|
| 1 | JSONL統一ログ設計 → GPT-5.4 | 😎GPT | 1日 |
| 2 | human-readable log実装 | 😎GPT→🤓Codex | 2日 |
| 3 | cause-chain実装 | 😎GPT→🤓Codex | 2日 |
| 4 | daily ops digest（Telegram自動送信） | 😎GPT | 1日 |
| 5 | RUNBOOK.md（GPT-3.5でも読める） | 😎GPT | 1日 |
| 6 | incident report自動生成 | 😎GPT→🤓Codex | 2日 |
| 7 | FL3レビュー + デプロイ | 全員 | 3日 |

---

## ⏱️ 全体タイムライン

```
3/11-12  Phase 1 Step 1-4（即実行）
3/12-13  Phase 1 Step 5-7（watchdog検証）
3/13-14  Phase 1 shadow 24時間
3/14     Phase 1 完了 ✅
3/15-21  Phase 2（黙らない）
3/22-    Phase 3（自己説明）
4月上旬   全Phase完了目標
```
