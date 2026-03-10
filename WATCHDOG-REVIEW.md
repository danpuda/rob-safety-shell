# watchdog skill レビュー結果

## 基本情報
- 名前: openclaw-watchdog
- バージョン: 1.3.0
- 作者: Abdullah4AI
- 更新日: 2026-03-10
- ⭐: 2,499
- **⚠️ VirusTotalでsuspicious判定**

## 8項目チェック（SKILL.mdベース）

### 1. restart条件
- 15秒ごとにGateway healthエンドポイントをping
- **3回連続失敗**でrestart試行
- ✅ 1回の失敗では動かない。3回は妥当

### 2. backoff実装
- restart試行は**最大2回**
- 2回失敗 → ユーザーにTelegram通知して reinstall許可を求める
- ユーザーが `touch ~/.openclaw/watchdog/approve-reinstall` するまで待つ
- ✅ backoffあり。人間承認ゲート付き

### 3. systemdの触り方
- `openclaw gateway restart` コマンドを使用
- systemctl直叩きではない
- ⚠️ `openclaw gateway restart` はメモリ上の状態をファイルに書き戻す（auth上書き問題の原因）
- → 今回のauth-profiles問題と同じパターンのリスク

### 4. bonjour watchdogを使うか
- SKILL.mdには言及なし
- HealthエンドポイントのHTTP pingのみ
- ✅ bonjourは使ってない模様（Issue #30183の影響なし）

### 5. Telegram通知先
- **独自のTelegram Bot Token + Chat IDを使用**
- OpenClawのTelegram channelとは別
- 独自にBot作成が必要（@BotFather）
- ⚠️ AES-256で暗号化保存（machine-specific key）
- ✅ OpenClawの通知とは分離されてる

### 6. custom recovery scriptの実行条件
- 2回restart失敗 → 「reinstall permission」をTelegramで要求
- ユーザーが `touch approve-reinstall` で承認しない限り実行しない
- ✅ 人間承認ゲートあり。勝手に実行しない

### 7. configを勝手に書き換えないか
- SKILL.mdには設定書き換えの言及なし
- ⚠️ **watchdog.py (13KB) の中身を読まないと断定不可**
- → rate limitでダウンロードできず、本体コード未読

### 8. 危険コマンドの有無
- setup.sh (6.2KB) + watchdog.py (13KB) の中身が未確認
- SKILL.mdレベルでは `rm -rf ~/.openclaw/watchdog` がuninstall手順にある（これは想定内）
- ⚠️ **VirusTotalでsuspicious判定** — 本体コード確認が必須

## 🔴 VirusTotal suspicious判定について

clawhubが `install` 時に以下の警告を出した：
```
⚠️  Warning: "openclaw-watchdog" is flagged as suspicious by VirusTotal Code Insight.
This skill may contain risky patterns (crypto keys, external APIs, eval, etc.)
```

推測される原因：
- AES-256暗号化処理（crypto keys検知）
- Telegram API直接呼び出し（external APIs検知）
- これら自体は正当な機能だが、本体コード確認なしでは判断不可

## 📊 判定

### SKILL.md レベル: ⚠️ 条件付きOK
- restart条件、backoff、人間承認ゲートは良設計
- bonjourは使ってない
- 独自Telegram Botは分離設計で安全

### 本体コード: ❌ 未確認
- watchdog.py (13KB) が読めてない
- VirusTotalフラグの原因が不明
- **7番（config書き換え）と8番（危険コマンド）が未回答**

## ➡️ 次のアクション

### Option A: rate limit解除後に再ダウンロード → 本体コード読む
### Option B: watchdog skillは入れずにsystemd Restart=on-failureだけで運用
### Option C: 最小版watchdogを自作（healthエンドポイントpingだけ、50行）

**推奨: Option B（今のまま運用）+ Phase 2でprobe実装時に再検討**
理由: Phase 1の目的は「死なない」であり、systemdの自動restartで最低限カバーできてる。VirusTotalフラグ付きのコードを確認なしで入れるリスクは取らない。
