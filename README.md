# kjlb-rustfs-storage

RustFS (S3 互換オブジェクトストレージ) の Docker 構成。

## ドキュメント

- **[利用ガイド](docs/usage.md)** — アプリケーションから接続する方法
  （AWS CLI / boto3 / PHP / Go の設定例、署名付き URL、制約）
- **[運用ガイド](docs/operations.md)** — 構築・起動停止・TLS・バックアップ・
  監視・トラブルシューティング

## 構成

SNSD (Single Node Single Disk)。将来 SNMD へ拡張可能。

外部に公開しているポートは **nginx の 80 / 443 のみ**。
S3 API・コンソール・Grafana・Prometheus はすべて nginx 経由でアクセスする。

```
        外部
         │  80 / 443
    ┌────▼─────┐
    │  nginx   │
    └────┬─────┘
         │  /                → rustfs:9000  (S3 API)
         │  /rustfs/console  → rustfs:9001  (コンソール)
         │  /grafana/        → grafana:3000
         │  /prometheus/     → prometheus:9090
```

Docker Compose の profile でサービス群を切り替える。

| profile | サービス | 用途 |
| --- | --- | --- |
| （なし） | rustfs, volume-permission-helper | ストレージ本体 |
| `proxy` | nginx | 外部への唯一の入口（**必須**） |
| `observability` | otel-collector, prometheus, tempo, loki, grafana | 監視 |

## クイックスタート

Linux サーバー上での実行を前提とする（データを `/srv/rustfs/` に bind mount
するため、macOS の Docker Desktop ではそのままでは動かない）。

```sh
sudo mkdir -p /srv/rustfs/data /srv/rustfs/logs

cat > .env <<'EOF'
RUSTFS_ACCESS_KEY=<ACCESS_KEY>
RUSTFS_SECRET_KEY=<SECRET_KEY>
GRAFANA_ADMIN_PASSWORD=<PASSWORD>
EOF

docker compose --profile proxy up -d
```

詳細は [運用ガイド](docs/operations.md) を参照。

## 由来

[rustfs/rustfs](https://github.com/rustfs/rustfs) の `docker-compose.yml` および
`.docker/` 配下の設定を基に整理したもの。上流から変更した主な点:

- ディスク 4 本 → 1 本（SNSD）
- データ・ログを named volume から `/srv/rustfs/` の bind mount に変更
- nginx 以外のポート公開を廃止し、Grafana / Prometheus をサブパス配信に
- nginx を SigV4 対応に修正（`$http_host` 引き渡し、`proxy_cache_convert_head off`、
  keepalive、大容量オブジェクト向けのバッファリング無効化）
- Jaeger を削除（トレースは Tempo に集約）
- 全イメージのバージョンを固定
- ソースビルド用サービス (`rustfs-dev`) を削除し、公開イメージを使用
