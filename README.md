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

## 起動

```sh
# ストレージのみ
docker compose up -d

# 監視・プロキシ込み
docker compose --profile observability --profile proxy up -d
```

停止は `down`、データも消す場合は `down -v`。

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

1. `RUSTFS_VOLUMES=/data/rustfs{0...3}`
2. `rustfs_data_1` 〜 `rustfs_data_3` の volume 定義とマウントを追加
3. `volume-permission-helper` にも同じ volume をマウントし chown 対象に追加

## 由来

[rustfs/rustfs](https://github.com/rustfs/rustfs) の `docker-compose.yml` および
`.docker/` 配下の設定を基に、SNSD 向けに整理したもの。
上流から変更した主な点:

- ディスク 4 本 → 1 本（SNSD）
- Jaeger を削除（トレースは Tempo に集約）
- 全イメージのバージョンを固定
- ソースビルド用サービス (`rustfs-dev`) を削除し、公開イメージを使用
