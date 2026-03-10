## 4) Phase 1 → 2 → 3 最新ロードマップ

今の実装状況だと、Phase 1 は「コード生成完了」ではなく **shadow mode 導入直前** です。次の山は、shadow mode で誤検知と運用衝突を潰してから、本番有効化へ進めることです。既存環境には `rob-health-monitor.sh`、`openclaw-monitor.sh`、`resource-monitor.sh` の cron 運用があり、正午 restart まで残っているので、まずはここを安全に整理するのが優先です。

### Phase 1 残タスク — 死なない

担当は前回の体制をそのまま引き継ぎます。
🦞 Rob は司令塔・Git管理・実機検証、😎 GPT は設計/初版修正、🤓 Codex は bash リファクタ/レビュー、🟠 Sonnet は短い調査/FL3 です。

1. `common.sh` 分離反映
   担当: 😎 GPT → 🤓 Codex
   見積り: 0.5日

2. `openclaw-json-phase1.diff` を staging 反映
   担当: 🦞 Rob
   見積り: 0.25日

3. systemd user timer を shadow mode で有効化

   * `rob-observer.timer`
   * `rob-config-drift.timer`
   * `rob-resource.timer`
     担当: 🦞 Rob
     見積り: 0.25日

4. 24時間 shadow mode 観測

   * `events.jsonl` JSON 妥当性
   * Telegram 誤通知率
   * `restart-request.json` の発火頻度
   * port 18790 の ownership 安定性
     担当: 🦞 Rob、🤓 Codex 補助
     見積り: 1日

5. 危険 cron の停止

   * `rob-health-monitor.sh`
   * `resource-monitor.sh`
   * 正午 `systemctl --user restart openclaw-gateway.service`
     担当: 🦞 Rob
     見積り: 0.25日

6. `restart-arbiter.sh` の手動 dry run
   担当: 🦞 Rob
   見積り: 0.25日

7. 本番有効化

   * restart request を実運用に接続
   * 旧 restart 習慣を撤去
     担当: 🦞 Rob
     見積り: 0.25日

**Phase 1 完了条件**

* [ ] `events.jsonl` が 24 時間壊れない
* [ ] `events-human.log` だけで異常理由が読める
* [ ] 旧 cron restart が消えている
* [ ] `restart-arbiter.sh` だけが restart 実行者になっている
* [ ] config drift が 1 分以内に通知される
* [ ] false positive が「うるさすぎる」水準でない

---

3/6-3/7 の事故ログでは、WhatsApp health-monitor の再起動嵐、delivery queue 再試行、ロブ自身の並列外部 HTTP が重なってクラッシュを増幅しています。残課題として incident DB 自体が「並列外部 HTTP 制限」「Anthropic timeout 短縮」「OpenClaw 2026.3.2 更新」を挙げています。Phase 2 はこの “黙らない” に直結する項目です。

### Phase 2 — 黙らない

1. synthetic probe 追加

   * `openclaw gateway status`
   * `openclaw channels status --probe`
   * Telegram pairing 実送達確認
     担当: 😎 GPT → 🟠 Sonnet 調査 → 🦞 Rob 実験
     見積り: 1日
     根拠コマンド系は docs の command ladder と channels probe がそのまま使えます。

2. reply-age / session freshness 監視

   * `~/.openclaw/agents/main/sessions/*.jsonl` から最終応答時刻抽出
     担当: 😎 GPT
     見積り: 0.5日

3. 並列外部 HTTP 制限

   * Lobster パイプライン側 or AGENTS 運用制御
     担当: 🦞 Rob + 😎 GPT
     見積り: 1日
     incident DB 上で最優先残課題です。

4. `auto-checkpoint.sh` の path 制限

   * `git add -A` の面積縮小
   * protected path 除外
     担当: 🤓 Codex
     見積り: 0.5日

5. Anthropic timeout 短縮検討

   * 300s → 180s 候補
     担当: 🟠 Sonnet 調査 → 😎 GPT 設計 → 🦞 Rob 実験
     見積り: 0.5日
     これも incident DB の残課題です。

**Phase 2 完了条件**

* [ ] 沈黙系異常を journal だけでなく reply-age でも拾える
* [ ] synthetic probe で「alive but unusable」を検知できる
* [ ] 並列外部 HTTP の暴走を抑止できる
* [ ] checkpoint 系が保護パスを巻き込まない
* [ ] timeout / overloaded 系の通知がノイズ過多でない

---

Phase 3 は「ログがしゃべる」を完成させる段階です。今の common 化と JSONL 統一は土台としてかなり良く、次は cause-chain と日次 digest を乗せれば、ほぼ目的に届きます。既存の監視・checkpoint 系はすでにログを出していますが、いまは grep 前提で、説明責任の層が薄いです。

### Phase 3 — 自己説明できる

1. cause-chain 生成

   * 例: `embedded_run_timeout` → `restart_request_written` → `restart_denied_by_cooldown`
     担当: 😎 GPT
     見積り: 1日

2. ops digest 追加

   * 1日1回の人間向け要約
     担当: 🤓 Codex
     見積り: 0.5日

3. rollback runbook 半自動化

   * known-good 比較
   * rollback 候補提示
   * 人間 confirm 待ち
     担当: 😎 GPT → 🦞 Rob
     見積り: 1日

4. `RUNBOOK.md` / `PHASE-OPS.md` 整備

   * GPT-3.5でも読める文章で固定化
     担当: 🟠 Sonnet → 🦞 Rob
     見積り: 0.5日

**Phase 3 完了条件**

* [ ] 異常イベントに reason / action / next が揃う
* [ ] 1日の障害傾向を digest で追える
* [ ] rollback 候補を人間が即判断できる
* [ ] grep 地獄なしで対応順が分かる

---

### ブランチ戦略と PR 粒度

前回方針のままで大丈夫です。
OpenClaw 本体を大きく触らず、1 PR 1責務を守るのが最優先です。

推奨ブランチ:

* `feature/minsafe-shell-v1`
* `feature/common-lib-refactor`
* `feature/observer-shadow-mode`
* `feature/restart-arbiter-enable`
* `feature/phase2-synthetic-probe`
* `feature/phase2-reply-age-monitor`
* `feature/phase3-ops-digest`

PR ルール:

* 1 PR 1責務
* 300 LOC 超で分割
* config diff と shell script diff を分ける
* systemd/timer PR と observer ロジック PR を分ける

レビュー順:

1. 😎 GPT 初版
2. 🤓 Codex bash/python レビュー
3. 🟠 Sonnet FL3
4. 🦞 Rob 実機検証 / merge

必要なら次に、今の 4 本に対する **実際の “common.sh 適用済み全文” だけ** を 4 回に分けてベタ貼りします。
