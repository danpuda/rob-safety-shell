# GPT返信08 — 方針転換レビュー結果

## GPTの結論

Phase 1は**大幅に削れる**。削っていいのは「手段」であって、Phase 3のゴールは残せる。

## 残すもの（3つだけ）

### A. config-drift-check.sh（最小版: 80-140行）
- sha256sum比較 + dangerous keys diff + validate + Telegram通知 + JSONL 1行
- human log, state dedupe, cooldown, rollback, restart request → 全部削る

### B. dangerous_config_keys リスト（20キー）
- ハードコードでOK。Phase 2でyaml化

### C. JSONL event schema の設計思想
- Phase 1で全適用しない。Phase 3の核として思想だけ残す

## 捨てるもの

| ファイル | 理由 |
|---------|------|
| openclaw-monitor.sh v2 | watchdog skillで代替 |
| rob-health-monitor.sh v3 | watchdog skillと役割衝突 |
| restart-arbiter.sh | watchdog skillのbackoffで代替。**両方入れると三重統治** |
| common.sh | 自作1本なら共通化コスト > メリット |
| systemd timer 3本 → 1本 | config-drift用のみ残す |

## 重要な指摘

### restart-arbiter.sh + watchdog = 危険
> watchdog skill が restart/backoff を持つ。systemd も Restart=on-failure を持つ。
> さらに自作 arbiter も restart を握る。この三重構造は避けるべき。

→ **watchdogを採用するならarbiterは捨てる。arbiterを使うならwatchdogは入れない。両方はやらない。**

### watchdog skill導入は3段階
1. 導入前レビュー（SKILL.md + 実スクリプト読む）
2. Shadow mode（restart無効 or 通知のみ）
3. 本番有効化

## 更新版Phase 1（軽量版）

1. 本体設定hardening（agents.list deny + elevated false + security audit）
2. 危険cron整理（正午restart削除、重複監視cron削除）
3. watchdog skill検証（コードレビュー → shadow → 本番）
4. config-drift-check.sh最小版導入（timer 1本）
5. known-good初期化

## Phase 2-3は前回維持
- Phase 2: probe + reply-age + 並列HTTP制限
- Phase 3: JSONL統一 + cause-chain + ops digest + RUNBOOK（ゴール不変）
