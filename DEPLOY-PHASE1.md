# DEPLOY-PHASE1.md

## 目的

Phase 1 は **「死なない」** が目的です。  
やることは次の4つだけです。

1. restart 主体を 1 個にする  
2. config drift を 1 分以内に見える化する  
3. 既存監視スクリプトに JSONL / human log を足す  
4. cron の危険な重複起動を止める

この段階では、**OpenClaw 本体の大改造はしません**。  
また、**自動 rollback もしません**。  
まずは shadow mode で安全に観測し、その後に有効化します。

---

## 前提

実環境前提:

- OpenClaw binary  
  `/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw`
- config  
  `/home/yama/.openclaw/openclaw.json`
- scripts dir  
  `/home/yama/ws/scripts`
- state dir  
  `/home/yama/ws/state/rob-ops`
- logs dir  
  `/home/yama/ws/logs/rob-ops`
- systemd user unit  
  `openclaw-gateway.service`

---

## 配置ファイル一覧

### scripts
- `/home/yama/ws/scripts/openclaw-monitor.sh`
- `/home/yama/ws/scripts/rob-health-monitor.sh`
- `/home/yama/ws/scripts/restart-arbiter.sh`
- `/home/yama/ws/scripts/config-drift-check.sh`

### systemd user
- `~/.config/systemd/user/rob-observer.service`
- `~/.config/systemd/user/rob-observer.timer`
- `~/.config/systemd/user/rob-config-drift.service`
- `~/.config/systemd/user/rob-config-drift.timer`
- `~/.config/systemd/user/rob-resource.service`
- `~/.config/systemd/user/rob-resource.timer`

### config
- `/home/yama/ws/config/observer-rules.yaml`
- `/home/yama/ws/config/guard-policy.yaml`
- `/home/yama/ws/config/protected-paths.txt`

---

## 0. 事前バックアップ

最初に必ずバックアップを取ります。

```bash
mkdir -p /home/yama/ws/backup/phase1-$(date +%Y%m%d-%H%M%S)
cp /home/yama/.openclaw/openclaw.json /home/yama/ws/backup/phase1-$(date +%Y%m%d-%H%M%S)/openclaw.json.bak
cp /home/yama/ws/scripts/openclaw-monitor.sh /home/yama/ws/backup/phase1-$(date +%Y%m%d-%H%M%S)/openclaw-monitor.sh.bak 2>/dev/null || true
cp /home/yama/ws/scripts/rob-health-monitor.sh /home/yama/ws/backup/phase1-$(date +%Y%m%d-%H%M%S)/rob-health-monitor.sh.bak 2>/dev/null || true
cp /var/spool/cron/crontabs/$USER /home/yama/ws/backup/phase1-$(date +%Y%m%d-%H%M%S)/crontab.bak 2>/dev/null || crontab -l > /home/yama/ws/backup/phase1-$(date +%Y%m%d-%H%M%S)/crontab.bak
````

> 注意
> 上の例は timestamp が毎回変わるので、実際には最初に変数へ入れて使う方が安全です。

安全版:

```bash
TS="$(date +%Y%m%d-%H%M%S)"
BK="/home/yama/ws/backup/phase1-$TS"
mkdir -p "$BK"
cp /home/yama/.openclaw/openclaw.json "$BK/openclaw.json.bak"
cp /home/yama/ws/scripts/openclaw-monitor.sh "$BK/openclaw-monitor.sh.bak" 2>/dev/null || true
cp /home/yama/ws/scripts/rob-health-monitor.sh "$BK/rob-health-monitor.sh.bak" 2>/dev/null || true
crontab -l > "$BK/crontab.bak"
```

---

## 1. ディレクトリ作成

```bash
mkdir -p /home/yama/ws/state/rob-ops/known-good
mkdir -p /home/yama/ws/logs/rob-ops
mkdir -p /home/yama/ws/config
mkdir -p /home/yama/.config/systemd/user
```

known-good がまだ無い場合は初回だけ現 config をコピーします。

```bash
cp -n /home/yama/.openclaw/openclaw.json /home/yama/ws/state/rob-ops/known-good/openclaw.json
```

---

## 2. ファイル配置

各ベタ貼りファイルを以下の場所へ保存します。

```bash
chmod +x /home/yama/ws/scripts/openclaw-monitor.sh
chmod +x /home/yama/ws/scripts/rob-health-monitor.sh
chmod +x /home/yama/ws/scripts/restart-arbiter.sh
chmod +x /home/yama/ws/scripts/config-drift-check.sh
```

systemd user unit / timer も保存します。

```bash
systemctl --user daemon-reload
```

---

## 3. 構文チェック

### shell syntax

```bash
bash -n /home/yama/ws/scripts/openclaw-monitor.sh
bash -n /home/yama/ws/scripts/rob-health-monitor.sh
bash -n /home/yama/ws/scripts/restart-arbiter.sh
bash -n /home/yama/ws/scripts/config-drift-check.sh
```

### 実行権限確認

```bash
ls -l /home/yama/ws/scripts/openclaw-monitor.sh
ls -l /home/yama/ws/scripts/rob-health-monitor.sh
ls -l /home/yama/ws/scripts/restart-arbiter.sh
ls -l /home/yama/ws/scripts/config-drift-check.sh
```

### OpenClaw binary 確認

```bash
/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw --version
```

### config validate

```bash
/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw config validate --json
```

> TODO: 要確認
> `openclaw config validate --json` の出力 JSON 形式はバージョン差がありえるため、
> `ok / valid / success` のどれが来るかを実機で一度確認してください。

---

## 4. Shadow Mode 導入

### 4-1. 先に timer だけ入れる

最初は **observer / config drift / resource** だけ動かします。
この時点では `restart-arbiter.sh` を定期実行しません。
つまり **観測だけ** です。

```bash
systemctl --user enable --now rob-observer.timer
systemctl --user enable --now rob-config-drift.timer
systemctl --user enable --now rob-resource.timer
```

状態確認:

```bash
systemctl --user list-timers --all | grep -E 'rob-observer|rob-config-drift|rob-resource'
systemctl --user status rob-observer.timer --no-pager
systemctl --user status rob-config-drift.timer --no-pager
systemctl --user status rob-resource.timer --no-pager
```

### 4-2. 手動1回実行

```bash
/home/yama/ws/scripts/openclaw-monitor.sh
/home/yama/ws/scripts/rob-health-monitor.sh
/home/yama/ws/scripts/config-drift-check.sh
```

### 4-3. 出力確認

```bash
tail -n 20 /home/yama/ws/logs/rob-ops/events.jsonl
tail -n 20 /home/yama/ws/logs/rob-ops/events-human.log
cat /home/yama/ws/state/rob-ops/gateway-status.json
cat /home/yama/ws/state/rob-ops/config-validate-last.json
cat /home/yama/ws/state/rob-ops/config-diff-last.json
```

期待値:

* JSONL が壊れていない
* `gateway-status.json` が生成される
* `config-validate-last.json` が生成される
* Telegram pairing に異常通知が届くなら文面に restart 指示が含まれていない

---

## 5. Shadow Mode 観測期間

まず **半日〜1日** は shadow mode で回します。
この期間は以下だけ確認します。

### 必須確認

1. `rob-health-monitor.sh` が毎分動く
2. `config-drift-check.sh` が毎分動く
3. `resource-monitor.sh` が 10 分ごとに動く
4. 誤通知が多すぎない
5. JSONL が 1 行 1 JSON で読める
6. systemd user timer が重複起動していない

確認コマンド:

```bash
journalctl --user -u rob-observer.service --since "-30 min" --no-pager
journalctl --user -u rob-config-drift.service --since "-30 min" --no-pager
journalctl --user -u rob-resource.service --since "-30 min" --no-pager
python3 - <<'PY'
import json
from pathlib import Path
p = Path("/home/yama/ws/logs/rob-ops/events.jsonl")
ok = 0
for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
    json.loads(line)
    ok += 1
print("jsonl_ok_lines=", ok)
PY
```

---

## 6. crontab の段階的停止

### Step 1: 先に停止するもの

以下は **timer 導入後に止めてよい** です。

* `rob-health-monitor.sh`
* `resource-monitor.sh`

### Step 2: 危険なので止めるもの

以下は **Phase 1 で必ず止める** です。

* `0 12 * * * systemctl --user restart openclaw-gateway.service`

### Step 3: 止めるか保留か

`openclaw-monitor.sh` は restart を持たなくなったので、
cron 側は止めてもよいですが、最初は手動運用でもよいです。
安全側なら **cron は止める** 方が整理しやすいです。

### 編集手順

```bash
crontab -e
```

削除 / コメントアウト対象はこの3本です。

```cron
* * * * * /home/yama/ws/scripts/rob-health-monitor.sh >/tmp/rob-health-monitor.cron.log 2>&1
*/10 * * * * /home/yama/ws/scripts/resource-monitor.sh >/tmp/resource-monitor.cron.log 2>&1
0 12 * * * systemctl --user restart openclaw-gateway.service >/tmp/openclaw-noon-restart.log 2>&1
```

必要なら `openclaw-monitor.sh` も止めます。

```cron
* * * * * /home/yama/ws/scripts/openclaw-monitor.sh >/tmp/openclaw-monitor.cron.log 2>&1
```

編集後確認:

```bash
crontab -l
```

---

## 7. restart-arbiter 有効化

Shadow mode で問題なければ、次に `restart-arbiter.sh` を有効化します。
ただし **いきなり timer 化せず**、最初は手動確認にします。

### 7-1. 疑似 request 作成

```bash
cat > /home/yama/ws/state/rob-ops/restart-request.json <<'EOF'
{
  "requestedAt": "2026-03-11T00:00:00+09:00",
  "requestType": "service_inactive",
  "severity": "critical",
  "reason": "manual dry run",
  "evidence": {
    "source": "deploy test"
  },
  "requestedBy": "manual-test"
}
EOF
```

### 7-2. 実行

```bash
/home/yama/ws/scripts/restart-arbiter.sh
```

### 7-3. 確認

```bash
tail -n 20 /home/yama/ws/logs/rob-ops/events.jsonl
tail -n 20 /home/yama/ws/logs/rob-ops/events-human.log
ls -l /home/yama/ws/state/rob-ops/restart-snapshots
cat /home/yama/ws/state/rob-ops/restart-history.json
```

### 期待値

* deny 条件なら deny が記録される
* 実際に restart が走った場合、pre/post snapshot が残る
* `restart-request.json` は処理後に消える

> 注意
> 本番で dry run するなら、**本当に restart が走ってよいタイミング** でやってください。
> requestType によっては service active なら deny されます。

---

## 8. openclaw.json 差分適用

Phase 1 の diff は **強め** です。
特に `main.tools.deny` に `exec` を入れているので、main agent はかなり制限されます。

### まずは review

```bash
cp /home/yama/.openclaw/openclaw.json /tmp/openclaw.json.before.phase1
```

### jq で pretty print

```bash
jq . /home/yama/.openclaw/openclaw.json > /tmp/openclaw.pretty.before.json
```

### 手動反映

`openclaw-json-phase1.diff` を見ながら、`agents` と `tools.elevated.enabled=false` を反映します。

### 適用後 validate

```bash
/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw config validate --json
```

### restart は直接しない

config 変更後の restart が必要でも、
**手動で `systemctl --user restart openclaw-gateway.service` を打たず**、
観測結果を見てから行います。

> TODO: 要確認
> OpenClaw 2026.3.2 の実環境で `agents.list[].tools.deny` が期待通り反映されるかは、
> 反映後に main / worker / codex それぞれで tool availability を実機確認してください。

---

## 9. 有効化後の確認項目

### systemd / service

```bash
systemctl --user status openclaw-gateway.service --no-pager
systemctl --user status rob-observer.timer --no-pager
systemctl --user status rob-config-drift.timer --no-pager
systemctl --user status rob-resource.timer --no-pager
```

### port owner

```bash
ss -ltnp '( sport = :18790 )'
systemctl --user show -p MainPID openclaw-gateway.service
```

### OpenClaw status

```bash
/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw gateway status
/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw channels status --probe
/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw health
```

### logs

```bash
tail -n 50 /home/yama/ws/logs/rob-ops/events.jsonl
tail -n 50 /home/yama/ws/logs/rob-ops/events-human.log
tail -n 50 /tmp/openclaw-monitor.log
tail -n 50 /tmp/rob-health-monitor.log
tail -n 50 /tmp/config-drift-check.log
```

---

## 10. ロールバック手順

### scripts 戻し

```bash
TS_BK="<backup timestamp>"
BK="/home/yama/ws/backup/phase1-$TS_BK"

cp "$BK/openclaw-monitor.sh.bak" /home/yama/ws/scripts/openclaw-monitor.sh 2>/dev/null || true
cp "$BK/rob-health-monitor.sh.bak" /home/yama/ws/scripts/rob-health-monitor.sh 2>/dev/null || true
```

### config 戻し

```bash
cp "$BK/openclaw.json.bak" /home/yama/.openclaw/openclaw.json
/home/yama/.nvm/versions/node/v22.22.0/bin/openclaw config validate --json
```

### timers 停止

```bash
systemctl --user disable --now rob-observer.timer
systemctl --user disable --now rob-config-drift.timer
systemctl --user disable --now rob-resource.timer
systemctl --user daemon-reload
```

### crontab 戻し

```bash
crontab "$BK/crontab.bak"
crontab -l
```

---

## 11. Phase 1 完了条件

以下を満たせば Phase 1 完了です。

1. `events.jsonl` が継続的に出る
2. `events-human.log` が人間可読
3. `gateway-status.json` が更新される
4. `config-drift-check.sh` が known-good 差分を拾う
5. 正午 restart cron が消えている
6. `rob-health-monitor.sh` と `resource-monitor.sh` が timer へ移行済み
7. restart 実行者が実質 `restart-arbiter.sh` だけになっている
8. port 18790 の二重所有が起きていない

---

## 12. Phase 1 でまだやらないこと

* 自動 rollback
* 全 cron の timer 移行
* sandbox 本格導入
* OpenClaw 本体 fork
* shell command text の完全フィルタ
* HITL 承認基盤

---

## 13. 次フェーズ入口

Phase 1 が安定したら、次にやるのはこの順番です。

1. synthetic probe
2. reply-age / session freshness 観測
3. auto-checkpoint の path 制限
4. worker/main の権限分離精緻化
5. main から `exec` を戻すかどうかの再評価

---

## 14. 最後の注意

この設計は **「全部守る」設計ではなく、「すぐ死ぬ事故だけ止める」設計** です。
最初からやりすぎると OpenClaw の速さが消えます。

Phase 1 では、

* restart を一本化
* drift を見える化
* 危険 cron を止める
* ログをしゃべらせる

ここまでで十分です。
