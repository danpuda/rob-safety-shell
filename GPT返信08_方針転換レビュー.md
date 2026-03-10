# GPT返信08 — 方針転換レビュー結果（正式版）

## GPTの結論

Phase 1は大幅に削れる。削るのは「手段」、Phase 3のゴールは残す。

## 残すもの（3つ）

1. **config-drift-check.sh 最小版**（80-140行。489行から85%削減）
   - sha256比較 + dangerous keys diff + validate + Telegram通知 + JSONL 1行
   - human log, state dedupe, cooldown, rollback, restart request → 削除

2. **dangerous_config_keys リスト**（20キー、ハードコードOK）

3. **JSONL event schema 設計思想**（Phase 3の核。Phase 1ではevents.jsonl 1行出力のみ）

## 捨てるもの

| ファイル | 理由 |
|---------|------|
| openclaw-monitor.sh v2 | watchdog skillで代替 |
| rob-health-monitor.sh v3 | watchdog skillと役割衝突 |
| restart-arbiter.sh | watchdogのbackoffで代替。両方入れると三重統治 |
| common.sh | 自作1本だけなので不要 |
| systemd timer 3本 → 1本 | config-drift用のみ |

## 重要な設計判断

### restart統制ルール
- watchdog採用 → arbiter捨てる
- arbiter採用 → watchdog入れない
- **両方はやらない**

### watchdog + config-drift の責務分離
- watchdog: 「死んだら起こす」（restart担当）
- config-drift: 「設定が壊れてるか監視」（restartしない）
- **混ぜない。「善意で壊す」が復活するから**

### watchdog skill導入は3段階
1. コードレビュー（8項目チェック）
2. Shadow mode（restart無効 or 通知のみ）
3. 本番有効化

## Phase 1（軽量版）4ステップ
1. 本体設定hardening（deny + elevated + security audit）
2. 危険cron整理（正午restart等の削除）
3. watchdog skill検証（レビュー → shadow → 本番）
4. config-drift-check.sh最小版 + timer 1本

## Phase 2-3（前回維持）
- Phase 2: probe + reply-age + 並列HTTP制限
- Phase 3: JSONL統一 + cause-chain + ops digest + RUNBOOK

## GPTの最終提案
> Phase 1は "OpenClawを信じる部分を増やし、自作はconfig integrityに限定する"

## ロブのレビュー追加メモ

### ⚠️ GPTが見落としてる点: restart統制の現実
GPTは「watchdogに任せればarbiter不要」と言ってるが、ロブの事故履歴では:
- cron、systemd、ロブ自身、watchdogの**4者がrestartを競合**した（port競合763回）
- watchdogを入れると**restart主体が増える**
- GPT自身も「restart主体を増やす設計は避けるべき」と言ってる

→ watchdog導入時は**既存のrestart系cronを必ず先に止める**（Phase 1-2を1-3より先にやる）

### ✅ 方針としては正しい
- 1,760行 → 80-140行は劇的改善
- 「OpenClawを信じる」は正しい（本体アプデで自作が壊れるリスク回避）
- config-driftだけ自作は事故パターンにピンポイント
