# Rob Safety Shell — Phase 2 & 3 設計+実装依頼

## あなたの役割
AIエージェント運用システムの設計者。bashスクリプト＋OpenClaw CLIで実装可能な最小設計を出してください。

## 背景

### システム構成
- **ロブ🦞**: OpenClawで動くAIエージェント（Claude Opus）。WSL2 Ubuntu上で24/7稼働
- **OpenClaw Gateway**: ロブの通信基盤。port 18790。systemdで管理
- **Telegram**: やまちゃん（人間）への通知チャンネル

### Phase 1（完了済み）で作ったもの
過去1ヶ月の29インシデントを分析し、「死なない」ための最小安全装置を実装した：

#### 1. config-drift-check.sh（196行）
- openclaw.jsonのハッシュをknown-goodと比較
- 危険キー変更を検知（elevated, auth, deny等）
- Telegram通知 + JSONL記録
- systemd timer: 毎分実行

#### 2. gateway-watchdog.sh（66行）
- http://127.0.0.1:18790/health にcurl
- 3回連続失敗でTelegram通知
- restart責務はsystemd Restart=on-failureに委譲（watchdog自体はrestartしない）
- 5分クールダウン（通知洪水防止）
- systemd timer: 毎分実行

#### 3. 本体設定hardening
- agents.list deny: ["group:automation"]
- tools.elevated.enabled: false
- chmod 600 openclaw.json
- 正午restart cron無効化

#### events.jsonlフォーマット（Phase 1で確立）
```json
{
  "ts": "2026-03-11T03:22:57+09:00",
  "layer": "observer",
  "component": "config-drift-check",
  "event": "config_drift_detected",
  "severity": "critical",
  "decision": "notify",
  "reason": "config drift detected",
  "target": "/home/yama/.openclaw/openclaw.json",
  "next_step": "review config",
  "evidence": { ... }
}
```

### 現在のcronジョブ（参考）
```
* * * * *   rob-health-monitor.sh       — ロブの生存監視
*/5         lobster-github-notify.sh    — GitHub変更通知
*/5         openclaw-monitor.sh         — OpenClaw監視
*/5         receiver-watchdog.sh        — カツアゲくん監視
*/10        auto-checkpoint.sh          — Git自動commit
*/10        check-pr-cron.sh            — Elvis式PR自動チェック
*/10        resource-monitor.sh         — リソース監視
*/30        auto-push.sh               — Git自動push
*/30        sync-chrome-history.sh     — Chrome履歴同期
0 * * * *   token-hourly-log.sh        — トークン使用量記録
```

### 通知コマンド（実証済み）
```bash
openclaw message send --channel telegram --target "8596625967" -m "メッセージ"
```

---

## Phase 2 要件: 「黙らない」

### 問題
Gateway のプロセスは生きているが応答しない（alive but unusable）パターンがある。Phase 1のwatchdogは `/health` が200を返せば「正常」とみなすが、実際にはセッションが死んでいて返答できない状態がある。

### 必要な機能

#### 2-1. Synthetic Probe（合成リクエスト）
- 定期的にロブに「テストメッセージ」を送り、返答が返るか確認
- 返答がN秒以内に来なければ「無言停止」と判定 → Telegram通知
- **制約**: OpenClaw APIで実現可能な方法であること。外部サービス依存NG

#### 2-2. Reply-Age検知
- ロブの最後の返答からの経過時間を監視
- N分以上返答がなければ「無言停止の可能性」→ Telegram通知
- ただし深夜（やまちゃんが話しかけてない時間帯）はfalse positive防止が必要
- **ヒント**: OpenClawのログ or セッション情報から最終返答時刻を取得できるか？

#### 2-3. 並列外部HTTP制限
- web_search/web_fetchを同時2個以上実行するとGateway即死する（INC-019）
- ロブ（AIエージェント）の行動制約として、openclaw.jsonの設定 or スクリプトで制限できるか？
- **注**: これはAIの行動制御の問題。bash scriptでは解決しにくいかもしれない

### 設計方針
- Phase 1と同じ: 最小構成、bashスクリプト、OpenClaw CLI活用
- events.jsonlに同じフォーマットで記録
- systemd timerで定期実行
- **通知のみ。自動修復はしない**

---

## Phase 3 要件: 「自己説明できる」

### 問題
何か起きた時に「何が起きたか」を人間が追えない。ログはあるが散在していて、JSONLを生で読むのは辛い。

### 必要な機能

#### 3-1. Human-Readable Log
- events.jsonlの各エントリを1行の日本語テキストに変換
- 例: `03:22 🚨 config改ざん検知: tools.elevated.enabled が false→true に変更された`
- 例: `03:56 ✅ Gateway正常: 応答200ms`

#### 3-2. Daily Ops Digest
- 1日の終わり（または朝）にTelegramで日次サマリを自動送信
- 内容:
  - 「平和だった」or「N回障害があった」
  - 障害があった場合: 時刻、何が起きたか、対応結果
  - Gateway稼働率（%）
  - config変更回数
- **フォーマット**: Telegramで読みやすい短いメッセージ（10行以内）

#### 3-3. Cause-Chain（原因連鎖）
- 複数のイベントを時系列で繋げて「何が何を引き起こしたか」を表示
- 例: `config変更 → validate失敗 → gateway不安定 → 3回連続失敗 → 通知`
- events.jsonlのcomponent + timestampで自動的に連鎖を推定

#### 3-4. RUNBOOK.md自動生成
- events.jsonlに記録されたイベントタイプごとに「何をすべきか」を記載
- GPT-3.5でも読める平易な日本語
- 例:
  ```
  ## config_drift_detected
  何が起きた: openclaw.jsonが変更された
  確認すること: git diff で何が変わったか見る
  対処法: 意図した変更なら known-good を更新。意図してなければ git checkout で戻す
  ```

### 設計方針
- human-readable logとdigestは1つのスクリプトにまとめてOK
- cause-chainは難しければPhase 3.5に回してOK
- RUNBOOK.mdは静的ファイルでOK（自動生成は将来）
- **「GPT-3.5でも読める」= 専門用語を使わない、手順を具体的に書く**

---

## 出力フォーマット

各機能について以下を出してください：

1. **ファイル名と行数の見積もり**
2. **完全な実装コード**（bashスクリプト）
3. **systemd timer/serviceファイル**（必要な場合）
4. **テスト手順**（正常系+異常系）
5. **既存スクリプトとの統合ポイント**

### コーディング規約（Phase 1に合わせる）
- `set -euo pipefail` + `trap 'on_error ${LINENO}' ERR`
- 設定は環境変数（`${VAR:-default}`）で上書き可能に
- Telegram通知: `openclaw message send --channel telegram --target "$TELEGRAM_TARGET" -m "メッセージ"`
- JSONL: events.jsonlに追記（同じスキーマ）
- flock多重実行防止
- 機密情報ハードコード禁止
