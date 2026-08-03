# kjlb-rustfs-storage

RustFS (S3 互換オブジェクトストレージ) の Docker 構成。

## 構成

SNSD (Single Node Single Disk)。将来 SNMD へ拡張可能（下記参照）。

Docker Compose の profile で 3 段階に分かれる。

| profile | サービス | 用途 |
| --- | --- | --- |
| (なし) | rustfs, volume-permission-helper | ストレージ本体 |
| `observability` | otel-collector, prometheus, tempo, loki, grafana | 監視 |
| `proxy` | nginx | リバースプロキシ |

## 前提

Linux サーバー上での実行を前提とする。データとログはホストの `/srv/rustfs/` に
bind mount するため、macOS の Docker Desktop では `/srv` が既定で共有されておらず
そのままでは起動しない（File Sharing に追加するか、パスを書き換える必要がある）。

## 起動

```sh
# ストレージのみ
docker compose up -d

# 監視・プロキシ込み
docker compose --profile observability --profile proxy up -d
```

停止は `down`。データは `/srv/rustfs/` に残るため、消す場合はホスト側で削除する
（`down -v` で消えるのは監視スタックの named volume のみ）。

## エンドポイント

| URL | 内容 |
| --- | --- |
| http://localhost:9000 | S3 API |
| http://localhost:9001 | RustFS コンソール |
| http://localhost | nginx 経由の S3 API |
| http://localhost/rustfs/console | nginx 経由のコンソール |
| http://localhost:3000 | Grafana（RustFS ダッシュボード 7 種を自動プロビジョニング） |
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
```

ホスト側ポートが他プロセスと衝突する場合は `.env` で上書きできる。
`RUSTFS_API_PORT` / `RUSTFS_CONSOLE_PORT` / `PROMETHEUS_PORT` / `GRAFANA_PORT` /
`TEMPO_PORT` / `LOKI_PORT` / `NGINX_HTTP_PORT` / `NGINX_HTTPS_PORT`。

## テレメトリの流れ

```
rustfs --OTLP--> otel-collector --+--> tempo      (トレース)
                                  +--> prometheus (メトリクス, 8889 を scrape)
                                  +--> loki       (ログ)
                                          |
                                       grafana
```

設定ファイルは `.docker/observability/` 配下。

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
