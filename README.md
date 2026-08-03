# kjlb-rustfs-storage

RustFS (S3 互換オブジェクトストレージ) の Docker 構成。

## 構成

SNSD (Single Node Single Disk)。将来 SNMD へ拡張可能（下記参照）。

Docker Compose の profile で 3 段階に分かれる。

| profile | サービス | 用途 |
| --- | --- | --- |
| (なし) | rustfs, volume-permission-helper | ストレージ本体 |
| `observability` | otel-collector, prometheus, tempo, loki, grafana | 監視 |
| `proxy` | nginx | リバースプロキシ（S3 API への唯一の入口） |

rustfs はホストにポートを公開しない。S3 API とコンソールへのアクセスは
すべて nginx 経由に限定しているため、**`proxy` profile が必須**。

## 前提

Linux サーバー上での実行を前提とする。データとログはホストの `/srv/rustfs/` に
bind mount するため、macOS の Docker Desktop では `/srv` が既定で共有されておらず
そのままでは起動しない（File Sharing に追加するか、パスを書き換える必要がある）。

## 起動

```sh
# ストレージ + プロキシ（通常はこれ）
docker compose --profile proxy up -d

# 監視込み
docker compose --profile proxy --profile observability up -d
```

停止は `down`。データは `/srv/rustfs/` に残るため、消す場合はホスト側で削除する
（`down -v` で消えるのは監視スタックの named volume のみ）。

## エンドポイント

| URL | 内容 |
| --- | --- |
| http://localhost/ | S3 API（nginx 経由） |
| http://localhost/rustfs/console | RustFS コンソール（nginx 経由） |
| http://localhost/grafana/ | Grafana（nginx 経由。RustFS ダッシュボード 7 種を自動プロビジョニング） |
| http://localhost:9090 | Prometheus |
| http://localhost:3200 | Tempo |
| http://localhost:3100 | Loki |

## データ配置

| ホスト | コンテナ | 内容 |
| --- | --- | --- |
| `/srv/rustfs/data` | `/data` | オブジェクトデータ（SNSD では `/data/rustfs0`） |
| `/srv/rustfs/logs` | `/logs` | RustFS のログ |

bind mount 先は Docker が root 所有で作成するため、`volume-permission-helper` が
起動前に RustFS の実行ユーザ (10001:10001) へ chown する。

監視スタックのデータ (Prometheus / Grafana / Tempo / Loki) は named volume を使う。

## 設定 (.env)

`.env` は Git 管理外。認証情報は必ず変更すること。

```sh
RUSTFS_ACCESS_KEY=...
RUSTFS_SECRET_KEY=...

# 監視スタックを使う場合のみ設定する（未設定だとテレメトリを送信しない）
RUSTFS_OBS_ENDPOINT=http://otel-collector:4318

# Grafana 管理者（既定は admin / admin）
GRAFANA_ADMIN_USER=...
GRAFANA_ADMIN_PASSWORD=...
GRAFANA_ROOT_URL=https://storage.example.com/grafana/
```

ホスト側ポートが他プロセスと衝突する場合は `.env` で上書きできる。
`NGINX_HTTP_PORT` / `NGINX_HTTPS_PORT` / `PROMETHEUS_PORT` / `TEMPO_PORT` / `LOKI_PORT`。

Grafana も rustfs と同様にホストへポートを公開せず、nginx の `/grafana/` 配下で配信する。
外部から見えるホスト名が `localhost` 以外の場合は `.env` で `GRAFANA_ROOT_URL` を設定する
（例: `GRAFANA_ROOT_URL=https://storage.example.com/grafana/`）。

## テレメトリの流れ

```
rustfs --OTLP--> otel-collector --+--> tempo      (トレース)
                                  +--> prometheus (メトリクス, 8889 を scrape)
                                  +--> loki       (ログ)
                                          |
                                       grafana
```

設定ファイルは `.docker/observability/` 配下。

## nginx と SigV4

S3 の SigV4 署名は **Host ヘッダとリクエストパスを署名対象に含む**ため、
プロキシで以下をやると `SignatureDoesNotMatch` になる。設定変更時は要注意。

- サブパスでの配信（`https://example.com/s3/` など）。S3 API は必ずルート `/` で配信する
- パスの書き換え（`proxy_pass` の末尾に URI を付ける、`rewrite` など）
- Host ヘッダの差し替え。`$host` はポート番号を落とすため `$http_host` を使う
- HEAD → GET 変換（nginx の既定動作）。`proxy_cache_convert_head off` で明示的に切る

なお nginx の location prefix はパス形式 S3 の先頭セグメント（バケット名）と
名前空間を共有するため、**`rustfs` と `grafana` という名前のバケットは作らないこと**。

Grafana は `observability` profile のみに存在するため、nginx はその不在時でも
起動できるよう Docker 内蔵 DNS で実行時に名前解決している（`proxy` profile 単独で
起動した場合、`/grafana/` は 502 を返す）。

## TLS

nginx で TLS 終端する場合は `.docker/nginx/ssl/` に証明書を配置し、
`.docker/nginx/nginx.conf` の 443 サーバーブロックのコメントを外す。

## SNMD への移行

`compose.yaml` の rustfs サービスを次のように変更する。

1. `RUSTFS_VOLUMES=/data/rustfs{0...3}` に変更
2. ホスト側で各物理ディスクを `/srv/rustfs/data/rustfs0` 〜 `rustfs3` にマウント

bind mount は `/srv/rustfs/data` ごと渡しているため、compose 側の volumes 定義は
変更不要。chown も `volume-permission-helper` が再帰的に処理する。

## 由来

[rustfs/rustfs](https://github.com/rustfs/rustfs) の `docker-compose.yml` および
`.docker/` 配下の設定を基に、SNSD 向けに整理したもの。
上流から変更した主な点:

- ディスク 4 本 → 1 本（SNSD）
- ストレージのデータ・ログを named volume から `/srv/rustfs/` の bind mount に変更
- Jaeger を削除（トレースは Tempo に集約）
- 全イメージのバージョンを固定
- ソースビルド用サービス (`rustfs-dev`) を削除し、公開イメージを使用
- rustfs と Grafana のポート公開をやめ、nginx 経由のみに限定
- nginx を SigV4 対応に修正（`$http_host` 引き渡し、`proxy_cache_convert_head off`、
  keepalive、大容量オブジェクト向けのバッファリング無効化）
