# kjlb-rustfs-storage

RustFS (S3 互換オブジェクトストレージ) の Docker 構成。

## ドキュメント

- **[利用ガイド](docs/usage.md)** — アプリケーションから接続する方法
  （AWS CLI / boto3 / PHP / Go の設定例、署名付き URL、制約）
- **[運用ガイド](docs/operations.md)** — 構築・起動停止・TLS・バックアップ・
  監視・トラブルシューティング
- **[.docker/ 設定リファレンス](docs/docker.md)** — 本リポジトリの `.docker/`
  配下について（監視スタックは別リポジトリに分離済み）

## 構成

SNSD (Single Node Single Disk)。将来 SNMD へ拡張可能。

各サービスがホストへ自身のポートを直接公開する（S3 API: 9000, コンソール: 9001）。
リバースプロキシ（TLS 終端、集約ドメインなど）が必要な場合は、本リポジトリの外で
別途用意し、これらのポートへ接続する。

| サービス | 既定ポート | 環境変数 |
| --- | --- | --- |
| S3 API | 9000 | `RUSTFS_S3_PORT` |
| コンソール | 9001 | `RUSTFS_CONSOLE_PORT` |

Grafana / Prometheus / Tempo / Loki による監視は、別リポジトリ
[kjlb-observability-stack](../kjlb-observability-stack) に分離してある。
本リポジトリとの連携は `.env` の `RUSTFS_OBS_ENDPOINT`（OTLP 送信先）のみ。

## クイックスタート

Linux サーバー上での実行を前提とする（データを `/srv/rustfs/` に bind mount
するため、macOS の Docker Desktop ではそのままでは動かない）。

```sh
make env      # .env を生成 (秘密情報はランダム生成)
make setup    # データディレクトリを作成
make up       # 起動 (rustfs のみ)
make health   # 疎通確認
```

設定項目は `.env.example` を参照。`make env-check` で不足や弱い値を確認できる。

よく使う操作は Makefile にまとめてある。`make` で一覧を表示。

```
make up          起動する
make down        停止する
make ps          コンテナの状態を表示する
make logs S=rustfs  ログを追う
make health      各サービスの疎通を確認する
make s3-check    S3 の疎通を確認する (署名・HEAD・特殊文字キー)
make backup DEST=... オブジェクトデータをバックアップする
```

詳細は [運用ガイド](docs/operations.md) を参照。

## 由来

[rustfs/rustfs](https://github.com/rustfs/rustfs) の `docker-compose.yml` および
`.docker/` 配下の設定を基に整理したもの。上流から変更した主な点:

- ディスク 4 本 → 1 本（SNSD）
- データ・ログを named volume から `/srv/rustfs/` の bind mount に変更
- nginx リバースプロキシを廃止し、各サービスがホストへ直接ポートを公開する構成に変更
  （リバースプロキシが必要な場合は本リポジトリの外で別途用意する）
- Jaeger を削除（トレースは Tempo に集約）
- 全イメージのバージョンを固定
- ソースビルド用サービス (`rustfs-dev`) を削除し、公開イメージを使用
