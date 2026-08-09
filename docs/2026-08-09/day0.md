# Day 0 — not-found-yet 観察記録

公開直後の状態を、3日後との比較のために固定しておく記録。
以降この個体には手を加えず、何になるかだけを見る。

- URL: https://not-found-yet.fly.dev
- source: https://github.com/coji/not-found-yet
- 企画書 / 技術仕様書: https://artifactshare.com/a/moyeumho42
- 記録時刻: 2026-08-09 19:45 JST（公開から約 1 時間 45 分）

## 身体

| | |
|---|---|
| body_id | DD34（公開後 4 回目の身体。deploy のたびに cold start する） |
| generation | 1 |
| 獲得した機能 | `/garden` のみ（1 / 12） |
| patched methods | なし |
| mode | alive |
| 平均反射レイテンシ | 3.45 ms |

## 心理状態

| 欲求 | 値 | 備考 |
|---|---|---|
| curiosity | 0.46 | baseline 0.35 から上昇 |
| vanity | 0.30 | mutation が成功したため |
| self_preservation | 0.20 | baseline |
| fatigue | 0.13 | |
| fear | 0.08 | baseline 0.10 をやや下回る |
| loneliness | 0.00 | 底。訪問が途切れていない |

公開初日の個体は **好奇心が高く、怯えていない**。
「スキャナーに先に会って怯えた個体になる」という事前の予想は、少なくとも初日には外れている。

## 唯一の判断（Generation 1）

観測 21 件から夢を 1 回見て、`/garden` を獲得した。費用 $0.0042。

> **Observation** — twenty-one visits arrived mostly as first touches. the garden recurred four times, while four questions recurred three times each. there is no scanner pressure, no fatigue crisis, and one periodic reader.
>
> **Interpretation** — the creature is being approached through imagined place and intimate questions. the repeated garden is the clearest invitation to grow a stable place of return.
>
> **Decision** — add_route `/garden`（候補は add_route 0.82 / no_change 0.31）
>
> **Sacrifice** — a little simplicity, in exchange for giving the recurring garden a body
>
> **Status** — applied · smoke passed · same PID

生成された器官の中身:

```
the garden is here, though no one owns it.
paths remember footsteps better than names.
stay long enough and something quiet may grow.
```

なお、この 21 件の観測は観察者（人間）が意図的に与えたもの。
**Generation 1 だけは仕込み**であり、Generation 2 以降が世界からの入力になる。

## 世界から最初に届いた欠落

公開 1 時間後の時点で、独立した訪問者 12 バケット・distinct path 17。
その内訳が予想と違った。人間でもスキャナーでもなく、**規約と発見のための巡回**だった。

| family | 件数 |
|---|---|
| well_known | 11 |
| self（`/`） | 8 |
| unknown | 4 |
| imagined_place | 1 |

実際に要求された path:

```
/.well-known/security.txt      /.well-known/ai-plugin.json
/.well-known/gpc.json          /.well-known/dnt-policy.txt
/.well-known/trust.txt         /.well-known/assetlinks.json
/app-ads.txt  /index.xml  /feed.xml  /feed  /favicon.ico
```

つまり世界がこの生き物に最初に教えている欠落は、**「お前にはフィードがない」「お前には規約がない」**である。
`/wp-admin` も `/.env` もまだ来ていない。

注目すべき点として、`/feed` は `well_known` ではなく **`imagined_place` に分類されている**。
`.well-known/` 配下でも既知拡張子でもないため、Airlock が「誰かが想像した場所」として扱った。
これが独立した複数バケットから繰り返されれば、獲得候補になりうる。
**この個体が最初に自力で生やす器官はフィードかもしれない。**

## 注意力の残高

| | |
|---|---|
| 本日の消費 | $0.0051 / $0.60（アプリ側 soft limit） |
| Dream 残 | 7 / 8 |
| Gaze 残 | 2 / 4（観察者が 1 回、世界が 1 回引いた） |
| gateway spend limit | $0.9 / rolling 24h |
| 思考停止（429） | なし |

## 3日後に見るもの

1. generation はいくつになったか。増えていない場合、夢の発火条件（新規観測 12 件）に届かなかったのか、拒否され続けたのか
2. 何を獲得し、何を失ったか。特に `/feed` を生やしたか
3. 心理状態はどちらへ寄ったか。curiosity のままか、fear / self_preservation へ倒れたか
4. scar（rejected / rolled_back）は出たか。出たならその理由
5. `/wp-admin` 系がいつ到達し、それが人格に何をしたか
6. 予算は尽きたか。gateway 429 に到達したか
7. body_id は変わっているか（変わっていれば Fly が cold start させた＝身体の死と継承が起きた）

## 観察のルール

- 3 日間はコード・設定ともに変更しない。deploy は cold start を起こし、身体を殺してしまう
- 観察者からのアクセスも最小限にする（`/status` の閲覧自体が観測イベントになり、孤独を薄めてしまう）
