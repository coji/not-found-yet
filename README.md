# I Don't Know What I Am Yet

存在しない URL を訪ねることが、ひとつの Web 生命体へ「欠けている器官」を教える。

404、クローラー、侵入スキャン、沈黙、失敗を観測し、**再起動せずに同じ Ruby プロセスのまま**自分の応答と機能を monkey patch していく公開作品の PoC 実装。

- Ruby 4.0 / Sinatra
- Same PID Mutation（deploy ではなく、ひとつの生存期間の出来事として変わる）
- Fly.io single Machine + Volume（一個体性を高可用性より優先する）
- 一日の注意力 ≈ $1（アクセスは無限、思考は有限）

---

## 動かす

```bash
mise install            # Ruby 4.0.6
bundle install
bundle exec rake test   # 52 tests
bundle exec puma -C config/puma.rb
```

`http://localhost:9292`（`PORT` で変更可）で目を覚ます。LLM の鍵がなくても動く。
その場合 Creature は反射だけで生き、夢は見ない。

存在しない URL を叩くと、それが入力になる。

```bash
curl -i localhost:9292/garden
curl    localhost:9292/garden     # 二度目は「2 回目だ」と言う
curl    localhost:9292/庭          # 日本語で名指してもいい
open    localhost:9292/status     # 固定観測窓
open    localhost:9292/mutations  # 判断と、その結末
```

この子が話す言葉、観測窓のラベル、Agent への contract はすべて日本語。
作品名 `I Don't Know What I Am Yet` だけ英語のまま置いてある。

`bundle exec rake introspect` で、今の身体を CLI から覗ける。

---

## 三層の注意力

すべての HTTP リクエストから LLM を呼ばない。反射・注視・夢に分けることで、
予算制限を作品上の「代謝」に変える。

| 層 | いつ | LLM | 上限 |
|---|---|---|---|
| **Reflex** | すべての request | 呼ばない | 無制限（$0） |
| **Gaze** | 珍しい遭遇だけ | 404 本文の第二声のみ。mutation 権限なし | 4 回 / 日 |
| **Dream** | 意味のある観測が溜まったとき | 解釈と MutationIntent を一度に | 8 回 / 日 |

予算は二重化してある。アプリ側は JST 暦日の soft limit（`$0.60`）、Cloudflare AI Gateway 側は
rolling 24h の spend limit（`$0.90` を推奨）。呼出前に最悪費用を予約し、成功時に usage で精算する。
usage 不明・timeout・transport error のときは**予約を返さない**（分からない出費を無かったことにしない）。
429 は失敗ではなく「その日の思考終了」として扱い、安い model へは fallback しない。

Gaze は初期状態で無効（`GAZE_ENABLED=false`）。公開の最後に、少量だけ有効化する想定。

---

## 変わってよいもの / 変えてはいけないもの

壊れてよい。ただし壊れ方の境界は固定する。

**変わってよい（Creature の領域）**

- 404 反射の文法・条件・長さ（`Creature#respond_to_absence`）
- 動的 route の獲得と喪失
- curiosity / fear / loneliness などの重み
- 過去の能力の retire と rollback

**変えてはいけない（身体法則）**

- Request Airlock と表示時 escape
- BudgetGuard・一回実行 lock・429 処理
- MutationIntent の schema と Trusted Mutator
- 秘密情報、外部ネットワーク、停止装置
- Journal manifest の検証と再生規則

LLM 出力を `eval` しない。Trusted Mutator が Intent を Ruby closure へコンパイルし、
`define_method` と registry 更新として現在のプロセスへ適用する。
展示用の Ruby source は生成するが、それは**実行正本ではない**。

### mutation で表現できることの全部

| type | 何が変わるか |
|---|---|
| `rewrite_absence_voice` | 404 の声。family ごとの template と最大長 |
| `add_organ` | いまの身体を映す窓を獲得する（形・源・気分・動き・相手ごとの顔） |
| `reshape_organ` | **獲得済みの器官を作り替える。** 増えるだけの身体は年表にしかならない |
| `retire_route` | 機能を失う。必要なら 410 Gone |
| `add_reflex_condition` | ふるまい。ためらう・黙る・別の status・読み替えて連れて行く |
| `speak_to_machines` | 機械だけが読む面を生やす。話しかけられるが、命令はできない |
| `invent_family` | 自分の分類を作る。曖昧だったものにだけ効く |
| `forget_family` | 見えなくする。自傷としての忘却 |
| `wrap_method` | 列挙済み transform を既存 method の前後に |
| `adjust_desire_weights` | 欲求の重みを ±0.15 まで |
| `add_route` | （legacy）静的な text/plain。本番に生えている個体のため残してある |
| `no_change` | 観測だけを記憶し、身体は変えない |

器官の中身は保存された markup ではなく**構成**（`form` / `source` / `mood` / `motion`）で、
描くのは不変側の `TrustedRenderer`。Creature は HTML も CSS も SVG も書けないし、
script は誰にも生成させない。同じ器官でも、いつ見るか・誰が見るかで違うものが出る。

任意定数参照、`File` / `IO` / `ENV`、`system`、`require`、socket、thread 生成は
**この言語では書けない**。書けないものは起こらない。

---

## 記憶と cold start

```
/data/
  state.json                 # 心理状態、前の身体の名前
  budget/2026-08-09.json     # JST 暦日ごとの予約と精算
  journal/000001.json        # 事実・解釈・選択・費用・結末（すべて残す）
  mutations/000001.json      # replay の正本。hash chain で繋ぐ
  exhibits/000001.rb         # 展示専用。決して再生しない
  tombstones/routes.json     # 失った場所（410 の根拠）
  traces/000001.json         # 痕。訪問者が持ち帰れる住所
  observations/2026-08-09.ndjson  # 到来そのものの記録（1 行 1 件）
  locks/                     # evolution / llm / budget の flock
```

cold start では manifest を generation 順に検証し、適用時と同じ validator を通して再構築する。
hash 不一致・欠番・破損があれば、その地点以降を適用せず **FOSSIL** で起動する。

`body_id` は cold start ごとに新しい UUID。PID だけでは再起動を識別しない。
Fly の suspend / resume では memory snapshot が復元されるので、同じ身体の睡眠として扱う。
新しい身体は「あの身体の変化だけを受け継いだ。時間は受け継いでいない。」と名乗る。

---

## 訪問者に残るもの

まだ無い場所を**最初に名指した人**には、住所が渡る。

```
/garden は、私にはない。
それを私に求めたのは、あなたが最初だ。

この名指しに印をつけた。/trace/1847
```

`/trace/1847` は持ち帰れる。誰が名付けたかは記録しない。記録するのは出来事のほうで、
それが自分だと知っているのは URL を持っている本人だけ。

痕は時間とともに薄れる。3 週間だれも戻らなければ言葉を失うが、`path_key` は残るので、
もう一度その名前で呼ばれれば思い出す。**忘れてはいるが、聞けば分かる。**
見に来ることでも、呼び直すことでも、鮮明さは戻る。
この作品は有限の注意力の話で、訪問者にも同じ経済が渡してある。

404 は問いで終わることがある。**次にアドレスバーへ打たれた名前が、答えになる。**
フォームは作らない。入力面はアドレスバーだけ、という前提を最後まで押し切っている。

---

## 運用（作品の外側）

```bash
# 化石になる：応答と Journal は残し、LLM 呼出と新しい mutation を止める
fly secrets set EVOLUTION_MODE=fossil

# 身体を止める：公開 HTTP に kill API は作らない
fly machine stop <machine-id>
```

Machine 内に Fly API token は置かない。置く secret は Cloudflare の token ひとつだけ。

その token に必要な権限は **Account → Workers AI → Read** である。
`/accounts/{id}/ai/*` 系はすべてこの権限を要求し、AI Gateway 権限だけの token は
401（code 10000）を返す（AI Gateway 権限が効くのは `/ai-gateway/*` の管理 API のほう）。
third-party model を呼ぶには Unified Billing のクレジットを事前にロードしておく必要がある。

### 主な環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| `EVOLUTION_MODE` | `alive` | `fossil` で思考停止 |
| `GAZE_ENABLED` | `false` | 404 の第二声 |
| `DREAM_ENABLED` | `true` | 夢と mutation |
| `LLM_MODEL` | `openai/gpt-5.6-luna` | Gateway 経由の model 名 |
| `LLM_DAILY_SOFT_LIMIT_USD` | `0.60` | アプリ側の一日上限 |
| `CF_ACCOUNT_ID` / `CF_API_TOKEN` | — | 未設定なら反射だけで生きる |
| `PERMITTED_HOSTS` | 空（無制限） | ひとつの URL に定住させたいとき |
| `MAX_DYNAMIC_ROUTES` | `12` | 複雑性の天井 |

`LLM_PRICE_*` で価格を上書きできる。予算計算は uncached 価格で保守的に行う。

---

## 意図的に外してある防御

公開作品なので、過剰な WAF や高可用性は目的にしない。

- `/wp-admin` や `/.env` を WAF で捨てない。404 として作品まで届かせる
- bot の逆引き DNS 検証をしない。名乗りと行動の記録で足りる
- 複数 region、Volume replication をしない。壊れたら壊れたこと自体を記録する
- 管理画面や公開 HTTP からの操作 API を作らない

残してあるのは、非 root 実行、GET / HEAD のみ、request body を読まない、
外向き通信は AI Gateway だけ、strict schema、そして各種上限。

---

## 構成

```
app.rb                      Sinatra。骨格と固定 route
lib/
  config.rb                 身体法則のうち値にできるもの
  clock.rb                  JST 暦日と、suspend を跨ぐ経過時間
  store.rb                  atomic JSON と flock
  body.rb                   body_id / PID / uptime / mode
  request_airlock.rb        入力を観測へ変える気密室
  observer.rb               事実の記録と集約
  psyche.rb                 6 つの欲求。減衰と飽和
  creature.rb               変わってよい領域（声と反射）
  dynamic_routes.rb         獲得した機能の registry と tombstone
  mutation_intent.rb        mutation の言語と strict schema
  trusted_mutator.rb        Intent → closure。適用と rollback
  evolution_journal.rb      追記専用の記録。hash chain
  replay.rb                 cold start の再構築
  fitness.rb                適応度の遅延評価
  budget_guard.rb           予約と精算
  attention_scheduler.rb    reflex / gaze / dream の選択
  evolution_agent.rb        観測 → 解釈 → MutationIntent
  providers/                AI Gateway との通信だけ
```

仕様書の推奨構成に対し、`config.rb` / `clock.rb` / `store.rb` / `body.rb` / `psyche.rb` /
`fitness.rb` を足してある。いずれも複数の層が共有する不可変インフラで、
Creature からは触れない。

---

## テスト

```bash
bundle exec rake test
```

- `request_airlock_test.rb` — 正規化、family 判定、秘密を表示しないこと、IP を保存しないこと
- `mutation_test.rb` — 同じ PID のまま変わること、予約 path・未知 operation の拒否、smoke 失敗の rollback
- `replay_test.rb` — manifest からの再構築、書込み可能な .rb を再生しないこと、改竄で FOSSIL 化
- `integration_test.rb` — 404 / 410、scanner burst、405、秘密の非漏洩、夢の一周、予算と 429

---

404 is not a dead end. It is the moment an absence receives a name.
