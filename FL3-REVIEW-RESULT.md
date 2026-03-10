# FL3 レビュー結果 — config-drift-check-minimal.sh

## 📊 スコア

| レビュアー | スコア | 判定 |
|-----------|--------|------|
| 🤓 Codex (GPT-5.3) | 43/100 | REQUEST_CHANGES |
| 🟠 Sonnet | 28/100 | REQUEST_CHANGES |

## CRITICAL（修正必須）

### C-1: vm.runInNewContext() = 任意コード実行（Codex ✅ / Sonnet ✅）
- `vm.runInNewContext("(" + text + ")")` でconfigをコードとして評価
- Node.js公式: "vm moduleはセキュリティ機構ではない。信頼できないコードの実行に使うな"
- configが改ざんされたら任意コード実行
- **修正**: `JSON.parse(fs.readFileSync(p, "utf8"))` に置換

### C-2: gateway.auth.tokensの平文がevents.jsonlに残る（Codex ✅ / Sonnet ✅）
- dangerous keysのbefore/afterにトークン平文が含まれる
- events.jsonlに永続化 → 読めるユーザーにトークン漏洩
- Telegram通知はキー名のみで安全（値は送ってない）
- **修正**: sensitive keys（auth.tokens, *password*, *secret*）のvalueを`[REDACTED]`に置換

## HIGH（強く推奨）

### H-1: set -e で異常時に無通知終了（Codex ✅ / Sonnet ✅）
- nodeブロックやpython3が失敗 → script即死 → 通知なし
- **まさにdrift検知すべき場面で検知できない**
- **修正**: trapまたは `|| { emit_event "check_error" ...; exit 1; }`

### H-2: known-good自動初期化が侵害済み設定を正当化（Codex ✅ / Sonnet ✅）
- 初回実行時に現行configを無条件でknown-good化
- 既に改ざん済みなら改ざんがベースラインになる
- **修正**: 自動初期化を削除。手動cp必須 + エラーメッセージで案内

### H-3: systemd unit参照不整合（Codex ✅ / Sonnet ⚠️部分同意）
- -minimal版serviceが通常版スクリプトのパスを参照
- **修正**: パスを揃える

### H-4: DIFF_JSONが空/不正の時もset -eで無通知終了（Sonnet 🆕）
- nodeの出力が壊れた時、python3のjson.loads("")が例外 → 即死
- H-1の別パス。同じ修正で対応可能

## MEDIUM

| # | 指摘 | 出典 |
|---|------|------|
| M-1 | send_notice失敗が完全に飲まれる（fallbackなし） | Sonnet |
| M-2 | events.jsonl無制限増加（logrotateなし） | 両方 |
| M-3 | DIFF_JSONをsys.argvで渡す（ARG_MAX + fragile） | Sonnet |
| M-4 | VALIDATE_RAWもsys.argvで渡す | Sonnet |
| M-5 | JSON diffのnull vs 欠落が同一扱い | Codex |
| M-6 | Phase 3拡張性（schema_version等なし） | Codex |

## LOW

| # | 指摘 | 出典 |
|---|------|------|
| L-1 | /tmpロック（world-writable） | 両方 |
| L-2 | systemd hardening不足 | Codex |
| L-3 | node PATHハードコード | Sonnet |
| L-4 | state/logディレクトリのchmod未設定 | Sonnet |

## 🎯 修正必須（SHIPの最低条件）

1. `vm.runInNewContext` → `JSON.parse`
2. sensitive keysのvalueマスク
3. trap/error handler追加（無通知終了防止）
4. known-good自動初期化を削除 → 手動初期化 + エラーガイド
5. systemd unitのパス修正
