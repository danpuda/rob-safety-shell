# GPT-5.4への方針転換プロンプト — 既存ツール調査結果を踏まえた再設計依頼

## 状況

Phase 1コード（返信06-07）のレビュー中に「これ大掛かりすぎないか？」という疑問が出ました。
ロブ🦞が既存のOpenClawガードシステムを調査した結果、**かなり使えるものが既に存在する**ことが分かりました。

しかし同時に、既存ツールにも**バグやセキュリティリスク**があることも判明しています。

以下の調査結果を踏まえて、**「自作すべき部分」と「既存を使うべき部分」を切り分けた最適プラン**を設計してください。

---

## 調査結果: 既存ツール5つ

### 1. openclaw-watchdog（公式skill）
- **場所**: clawhub.com / openclaw/skills リポジトリ（⭐2,499）
- **機能**: Gateway死亡検知 + 自動restart + backoff + Telegram通知 + カスタム回復スクリプト
- **品質**: 公式リポジトリ内、LobeHub掲載、説明文は丁寧
- **⚠️ 既知バグ（Issue #30183）**: OpenClaw本体の内蔵bonjour watchdogがsystemd環境で11秒ごとに無限restart loopを起こすバグが報告されている（2026.2.26, Ubuntu arm64ネイティブ環境）
- **✅ うちの環境では未発生**: WSL2 + OpenClaw 2026.3.2で24時間分のjournalにbonjourログゼロ。WSL2ではbonjourサービスが動いていないため再現しない
- **判定**: 導入OK

### 2. openclaw-self-healing（Ramsbaby）
- **場所**: https://github.com/Ramsbaby/openclaw-self-healing（⭐12）
- **機能**: 4層回復（KeepAlive→Watchdog→AI修復→人間通知）。うちの設計とほぼ同じ思想
- **品質**: macOS LaunchAgent前提。Linux systemd対応は記載あるが未検証。⭐12と少ない
- **⚠️ リスク**: AI Emergency Recovery（Level 3）でClaude Code PTYを自動実行してログ読み→診断→修正する。これは「AIが勝手にシステムを修復する」ので、ロブの事故パターン（勝手に設定変更）と同じリスクがある
- **判定**: 思想は参考になるが、直接導入は危険

### 3. @pmatrix/openclaw-monitor（plugin）
- **場所**: npm / https://github.com/p-matrix/openclaw-monitor
- **機能**: リスクスコアでtool実行をブロック + credential漏洩検知 + kill switch
- **⚠️ リスク**: 外部API（api.pmatrix.io）に行動メタデータを送信する。プロンプト内容は送らないと主張しているが、ツール名・呼び出し回数・タイミングを外部サーバーに送る
- **判定**: 外部依存は避けたい。思想（リスクスコア方式）は参考程度

### 4. ClawSec（prompt-security）
- **場所**: https://github.com/prompt-security/clawsec（⭐260）
- **機能**: SOUL.md改ざん検知 + CVEアラート + セキュリティ監査 + チェックサム検証
- **⚠️ 注意**: セキュリティ特化（運用監視ではない）。やりたいこととスコープが違う
- **🔴 重要な背景**: Reddit調査（r/MachineLearning）で「OpenClawコミュニティskillの15%に悪意ある命令が含まれている」という報告あり。外部skillのインストール自体にリスクがある
- **判定**: スコープ外だが、skill導入時のリスク認識として重要

### 5. OpenClaw本体の組み込み機能
- **`tools.deny` / `group:automation`**: エージェント権限制限 ✅ 実機確認済み
- **`openclaw security audit`**: 設定の脆弱性チェック ✅ 実機確認済み
- **systemd Restart=on-failure**: 基本的なプロセス再起動 ✅
- **⚠️ 未実装提案（Discussion #12026）**: systemd WatchdogSecの統合が提案されているが未実装。「Gateway が生きてるけど応答しない」状態（silent hang）をsystemd標準で検知する仕組みはまだない
- **判定**: これが最も安全。まずここを最大限使うべき

---

## 調査結論: 何を自作すべきで何を既存で済ませるか

### ✅ OpenClaw本体の設定だけで済む（自作不要）
1. `agents.list[].tools.deny: ["group:automation"]` — Gateway/cron操作禁止
2. `tools.elevated.enabled: false` — 昇格実行禁止
3. systemd `Restart=on-failure` — 基本的なプロセス再起動
4. `openclaw security audit` — 定期監査

### ✅ 公式watchdog skillで済む（実機確認済み）
5. Gateway死亡検知 + 自動restart + backoff
6. Telegram通知
- Issue #30183（bonjour watchdog無限ループ）はWSL2環境では未発生（bonjourログゼロ、24h確認済み）

### ❌ 既存ツールではカバーできない（自作が必要）
7. **config drift検知** — ロブが設定ファイルを壊す事故パターンはうち固有。sha256比較 + dangerous keys差分はどのツールにもない
8. **危険cron一掃** — うちの19本cron問題はうち固有
9. **restart一元化** — 既存ツールは「restart するか否か」だけ。うちは「誰がrestartしていいか」の統制が必要（ロブ、cron、watchdog、systemdが全員勝手にrestartして競合した事故履歴がある）

---

## 依頼

以上を踏まえて、以下を設計してください：

### 1. 最適プラン（使い分け）
- OpenClaw本体設定（即適用）
- 公式watchdog skill（実機確認してから）
- 自作スクリプト（本当に必要な部分だけ）

返信06-07で書いたコードのうち、**どれを残してどれを捨てるか**を明確にしてください。

### 2. 自作が必要な部分の最小実装
- config-drift-check.sh は残す価値がある？ 最小限にするなら何行くらい？
- restart-arbiter.sh は公式watchdogと競合しない？
- common.sh は自作スクリプトが減るなら不要では？

### 3. 公式watchdog skill導入手順
- Issue #30183はWSL2環境で未発生を確認済み（bonjourログゼロ）
- ただしコミュニティskillの15%に悪意ある命令が含まれているという報告があるため、導入前にSKILL.mdとスクリプトのコード確認は必要
- watchdog skillと自作config-drift-check.shの共存設計

### 4. 更新されたロードマップ
- Phase 1を「本体設定 + 最小自作 + watchdog検証」に圧縮
- Phase 2-3は前回のまま（必要なら調整）

---

## 参考: 前回の返信で使えるもの・使えないもの

### 返信06-07で残す価値があるもの
- config-drift-check.sh の dangerous_config_keys リスト（20キー）
- observer-rules.yaml の設計思想（Phase 2以降で使う可能性）
- JSONL event schema（統一ログフォーマットとして有用）
- guard-policy.yaml（運用ルールの言語化として有用）

### 返信06-07で不要になる可能性があるもの
- openclaw-monitor.sh v2 → 公式watchdogで代替
- rob-health-monitor.sh v3 → 公式watchdog + config-drift-checkに分離
- restart-arbiter.sh → 公式watchdogのbackoffで代替？ or 共存？
- common.sh → 自作スクリプトが1-2本なら分離する意味がない
- systemd timer 6本 → 公式watchdogが自前timerを持つなら重複

---

## 制約

- 「全部自作」は大掛かりすぎる。最小限にしたい
- 外部API依存（pmatrix等）は避ける
- コミュニティskillは導入前にコード確認する
- Phase 1の目標は変わらない:「死なない」

## 🔴 絶対に失わせたくないもの

軽くするのはOKだが、以下の設計思想は最終ゴールとして必ず残すこと：

1. **「しゃべるシステム」** — 何が起きたかをシステムが自分で説明できること。ログをgrepして人間が推理するのではなく、「煙が出た→報知器が鳴った→でもクールダウン中で消防車は出なかった」が1行で読める。JSONL統一ログ + human-readable log + cause-chain はこのための仕組み。Phase 1で全部やらなくていいが、**Phase 3のゴールとしては残す**

2. **「GPT-3.5でも触れるRUNBOOK」** — 障害対応手順をやまちゃん🗻が自分で読めるレベルで文書化する。高度なAIじゃないと読めないログやドキュメントは意味がない。Phase 3のRUNBOOK.md整備はこのため

3. **「事故報告書の自動生成」** — 日次ops digest。「今日は平和だった」or「3回火事があった」が1日1回届く。やまちゃんが毎日ログを見に行かなくていい仕組み

つまり：**Phase 1は軽くする。でもPhase 3の「自己説明できるシステム」というゴールは消さない。**
軽量化の対象はPhase 1の実装手段であり、最終ビジョンではない。
