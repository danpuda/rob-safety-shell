# GPT-5.4への修正依頼プロンプト（Phase 1コードレビュー結果）

## 状況

返信06で受け取ったPhase 1実装コード（6ファイル）をロブ🦞が品質チェックしました。
bash -n構文チェックは全パス。アーキテクチャ（restart一元化、cooldown、JSONL統一）は素晴らしいです。

ただし **全部書き直しは不要** です。以下の **ピンポイント修正だけ** お願いします。

---

## 修正① 🔴 致命的: agents.list の exec deny を外す

`openclaw-json-phase1.diff` で `main` に `exec` を deny していますが、これをやるとロブ🦞が **何もできなくなります**（git, bash -n, curl, スクリプト実行すべて不可）。

**実機で確認した事実:**
- OpenClaw 2026.3.2 は `agents.list[].tools.deny` をサポート ✅（公式docs確認済み）
- `group:automation` = `cron` + `gateway` のグループ指定が使える ✅
- `group:runtime` = `exec` + `bash` + `process`（これを deny すると手足を縛る）

**修正案:**
```json5
{
  agents: {
    list: [
      {
        id: "main",
        tools: {
          deny: ["group:automation"],  // gateway + cron だけ禁止
          elevated: { enabled: false }
        }
      },
      {
        id: "worker",
        tools: {
          deny: ["group:automation"],
          elevated: { enabled: false }
        }
      },
      {
        id: "codex",
        tools: {
          deny: ["group:automation"],
          elevated: { enabled: false }
        }
      }
    ]
  }
}
```

`openclaw-json-phase1.diff` だけ修正版をください。

---

## 修正② ⚠️ 共通関数の重複 → lib/common.sh に分離

現在 `emit_event`, `emit_human_log`, `timestamp_jst`, `ts_iso`, `rotate_line_log`, `json_escape` が **4ファイル全部にコピペ** されています（1,760行中の推定40%が重複）。

**依頼:**
- `scripts/lib/common.sh` を新規作成（共通関数をここに集約）
- 4スクリプトの先頭で `source "$(dirname "$0")/lib/common.sh"` する
- `common.sh` だけ全文ください。4スクリプトの修正は差分（どの関数を消してsource行を足す）だけでOK

---

## 修正③ ⚠️ observer-rules.yaml が読まれてない

`config/observer-rules.yaml` に journal_patterns や dangerous_config_keys を定義していますが、スクリプト側はハードコードで同じ値を持っています（二重管理）。

**Phase 1ではハードコードのままでOK** です（yamlパース追加はPhase 2）。ただし：
- `observer-rules.yaml` のコメントに「Phase 1: この値はスクリプト内にもハードコード。Phase 2でyamlから読む予定」と明記してください
- スクリプト側にも「# TODO Phase 2: observer-rules.yaml から読む」コメントを足してください

これはコメント追加だけなので差分不要、common.shに含めてもらえればOK。

---

## 確認事項への回答（実機検証済み）

### `openclaw config validate --json` の出力形式
```json
{"valid":true,"path":"/home/yama/.openclaw/openclaw.json"}
```
→ キーは `valid`。あなたのコードは `ok / valid / success` の3パターン全部チェックしてるので **問題なし✅**

### `agents.list[].tools.deny` のサポート
→ 公式docs（docs.openclaw.ai/tools）で確認済み。**サポートされています✅**
- `group:runtime` = exec, bash, process
- `group:automation` = cron, gateway
- `group:fs` = read, write, edit, apply_patch
- agent別の `tools.profile` も使える（minimal/coding/messaging/full）

---

## 追加依頼: Phase 1→2→3 ロードマップの最新版

返信05でPhase 1-3のロードマップを出してもらいましたが、Phase 1のコードが実際にできた今、ロードマップを最新化してほしいです。

**含めてほしい内容:**
1. Phase 1の残タスク（shadow mode → 本番有効化のステップ）
2. Phase 2（黙らない）の具体タスクと担当・見積り
3. Phase 3（自己説明できる）の具体タスクと担当・見積り
4. 各Phaseの完了条件（チェックリスト形式）
5. ブランチ戦略とPR粒度（返信05で定義済みのものを引き継ぎ）

---

## まとめ: 出力してほしいもの

1. `openclaw-json-phase1.diff` 修正版（exec deny → group:automation deny）
2. `scripts/lib/common.sh` 全文
3. 4スクリプトへの修正差分（重複関数削除 + source追加）
4. Phase 1→2→3 最新ロードマップ

**全文書き直しは不要。上記のピンポイントだけでOK！**
