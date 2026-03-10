# GPT-5.4への依頼 — FL3レビュー結果に基づくconfig-drift-check.sh修正

## 状況

返信09のconfig-drift-check.sh最小版（164行）を2者レビューにかけました。

| レビュアー | スコア | 判定 |
|-----------|--------|------|
| Codex (GPT-5.3) | 43/100 | REQUEST_CHANGES |
| Sonnet (Claude) | 28/100 | REQUEST_CHANGES |

## 修正必須（CRITICAL + HIGH）— 5件

### C-1: vm.runInNewContext() → JSON.parse() に置換
- `vm.runInNewContext("(" + text + ")")` は任意コード実行リスク
- Node.js公式: "vm moduleはセキュリティ機構ではない"
- openclaw.jsonはJSONなので `JSON.parse` で十分
- **JSON5/コメント付きconfigの場合**: もしOpenClawが非標準JSONを使う可能性があるなら、`JSON.parse`で失敗した場合のエラーハンドリングを入れてください

### C-2: sensitive keysのvalue masking
- `gateway.auth.tokens` のbefore/afterが平文でevents.jsonlに永続化される
- Telegram通知側はキー名のみで安全（値は送ってない）→ 問題はJSONLログのみ
- **修正**: 以下のキーパターンに該当するvalueを `"[REDACTED]"` に置換
  - `gateway.auth.tokens`
  - `*password*`
  - `*secret*`
  - `*apiKey*`

### H-1 + H-4: set -eによる無通知終了の防止
- nodeブロック/python3失敗 → script即死 → drift検知できない
- **まさにdrift検知すべき場面で検知できない** という致命的問題
- **修正**: trap ERR またはcriticalセクションごとの `|| { emit_event "check_error" ...; exit 1; }`
- 最低限、「チェック自体が壊れた」ことをTelegram通知 + JSONL記録すること

### H-2: known-good自動初期化を削除
- 初回実行時に現行configを無条件でknown-good化 → 侵害済み設定が正当化される
- **修正**: 自動初期化を削除。代わりに:
  ```bash
  [[ -f "$KNOWN_GOOD_PATH" ]] || { echo "ERROR: known-good not initialized. Run: cp $CONFIG_PATH $KNOWN_GOOD_PATH"; exit 2; }
  ```

### H-3: systemd unitのパス修正
- serviceのExecStartが `/home/yama/ws/scripts/config-drift-check.sh`（通常版）を参照
- timerのUnitが `rob-config-drift.service`（通常版）を参照
- **修正**: 実際に使うファイル名に合わせてください。ファイル名は `config-drift-check.sh`（-minimalなし）で統一推奨

## 改善推奨（MEDIUM）— 対応推奨だがPhase 1ブロッカーではない

### M-1: send_notice失敗時のfallback
- `|| true` で完全に飲んでいる。`logger`(syslog) fallback推奨

### M-2: DIFF_JSONをsys.argvではなく環境変数またはstdinで渡す
- ARG_MAX問題 + 位置引数の脆さ

### M-3: events.jsonlのログローテーション
- Phase 1では `logrotate` 設定1つ追加で十分

## やらなくていいもの（LOWはPhase 2以降）

- /tmpロック → Phase 2でRuntimeDirectory化
- systemd hardening → Phase 2
- schema_version等 → Phase 3

## 出力してほしいもの

1. **修正版 config-drift-check.sh**（全文。CRITICAL 2件 + HIGH 3件 + MEDIUM対応推奨分を反映）
2. **修正版 systemd service + timer**（パス修正済み）
3. **logrotate設定**（events.jsonl用、1つだけ）
4. 修正のサマリ（何をどう変えたか一覧）

## 制約

- 行数目標: 200行以内（164行+修正で膨らむのはOKだが、200行を超えないよう）
- restartは引き続きしない（責務分離維持）
- common.shは作らない（1本で完結）
