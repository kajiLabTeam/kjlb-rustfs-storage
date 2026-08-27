# 運用ガイド

サーバー側の構築・運用手順。アプリケーションからの利用方法は
[usage.md](usage.md) を参照。

## 前提

- Linux サーバー（データを `/srv/rustfs/` に bind mount するため）
- Docker / Docker Compose v2

データの保存先は `.env` の `RUSTFS_DATA_DIR` / `RUSTFS_LOGS_DIR` で変更できる
（既定は `/srv/rustfs/data` と `/srv/rustfs/logs`）。

macOS の Docker Desktop では `/srv` が既定で共有されていないためそのままでは
起動しない。Docker Desktop の File Sharing に追加するか、`.env` で
リポジトリ配下などの共有済みパスを指定する。

```sh
RUSTFS_DATA_DIR=./data
RUSTFS_LOGS_DIR=./logs
```

## セットアップ

```sh
git clone <このリポジトリ>
cd kjlb-rustfs-storage

# データディレクトリを用意（保存先は .env の RUSTFS_DATA_DIR で変更可）
make setup

# 認証情報を設定（.env は Git 管理外）
make env          # .env.example から生成し、秘密情報はランダム生成される
$EDITOR .env      # ホスト名など環境に合わせて調整
make env-check    # 未設定・弱い値がないか確認

make up
```

`make setup` と `make up` でも同じことができる。

### .env の項目

全項目の説明は `.env.example` にある。要点は以下。

| 変数 | 未設定時 | 備考 |
| --- | --- | --- |
| `RUSTFS_ACCESS_KEY` | `rustfsadmin` | **必ず設定する**（既定値は公知） |
| `RUSTFS_SECRET_KEY` | `rustfsadmin` | **必ず設定する**。32文字以上を推奨 |
| `RUSTFS_OBS_ENDPOINT` | 空（送信しない） | 監視を使うなら別リポジトリ kjlb-observability-stack の `http://host.docker.internal:4318` |
| `RUSTFS_S3_PORT` | `9000` | 変更時はクライアントのエンドポイントURLにもポートを含める |
| `RUSTFS_CONSOLE_PORT` | `9001` | 同上 |
| `RUSTFS_DATA_DIR` | `/srv/rustfs/data` | オブジェクトデータの保存先（ホスト側） |
| `RUSTFS_LOGS_DIR` | `/srv/rustfs/logs` | ログの保存先（ホスト側） |

`.env` を変更したら、コンテナを再作成しないと反映されない。

```sh
make up   # 変更のあったサービスだけ再作成される
```

ディレクトリの所有者は `volume-permission-helper` が起動時に
RustFS の実行ユーザ (10001:10001) へ変更するため、手動の chown は不要。

## 起動と停止

Makefile に主要な操作をまとめてある（`make` で一覧）。
以下は同等の docker compose コマンド。

| make | docker compose |
| --- | --- |
| `make up` | `docker compose up -d` |
| `make down` | `docker compose down` |
| `make ps` | `... ps` |
| `make logs S=rustfs` | `... logs -f rustfs` |

```sh
# 起動
docker compose up -d

# 停止
docker compose down

# 状態確認
docker compose ps
```

## ネットワーク境界

rustfs がホストへ自身のポートを直接公開する。

| サービス | ポート | 環境変数 |
| --- | --- | --- |
| rustfs（S3 API） | 9000 | `RUSTFS_S3_PORT` |
| rustfs（コンソール） | 9001 | `RUSTFS_CONSOLE_PORT` |

本リポジトリはリバースプロキシを含まない。外部公開・TLS 終端・ドメインの
集約などが必要な場合は、別途用意するリバースプロキシからこれらのポートへ
接続する構成を想定している（プロキシの設定自体は本リポジトリのスコープ外）。

監視（Grafana / Prometheus / Tempo / Loki / otel-collector）は別リポジトリ
[kjlb-observability-stack](../../kjlb-observability-stack) に分離してある。
本リポジトリの rustfs サービスは `extra_hosts` で `host.docker.internal` を
解決できるようにしてあり、`RUSTFS_OBS_ENDPOINT` にその監視スタックの
otel-collector のホスト公開ポート（既定 `http://host.docker.internal:4318`）を
設定すればテレメトリを送信できる。

## TLS

本リポジトリの構成自体は TLS を終端しない。TLS が必要な場合は、外部に
用意するリバースプロキシ側で証明書を配置し、各サービスのポート
（9000 / 9001 / 3000 / 9090）へ接続する構成にすること。

リバースプロキシの `server_name` / Host ヘッダは**クライアントが実際に
アクセスするホスト名と一致させる**こと。SigV4 の署名には Host ヘッダが
含まれるため、ここがずれると認証が通らない。

## リバースプロキシを構成する際の注意（SigV4）

S3 の SigV4 署名は **HTTP メソッド・リクエストパス・Host ヘッダ**を
署名計算に含む。プロキシがこれらを書き換えると `SignatureDoesNotMatch` になる。
外部にリバースプロキシを立てる場合は以下を壊さないこと。

| 守ること | 理由 |
| --- | --- |
| S3 API のパスをリライト・正規化しない | パスを書き換えると、記号や日本語を含むキーで署名が壊れる |
| サブパス配信にしない（`/s3/` 等を前置しない） | 先頭セグメントはバケット名でもあるため、署名とパスの解釈が壊れる |
| Host ヘッダをそのまま転送する | ポート番号込みの Host ヘッダで署名されるため、書き換えると署名と食い違う |
| HEAD リクエストを GET に変換しない（キャッシュ設定に注意） | メソッドが変わると署名が壊れる |

変更後は必ず以下で疎通確認する。

```sh
make s3-check       # 署名・HEAD・特殊文字キーの疎通確認
```

## バックアップ

SNSD 構成には冗長性が無い。ディスク障害＝データ損失になるため、
バックアップは必須。

```sh
# ローカルの別ディスクへ
make backup DEST=/mnt/backup/rustfs

# 別ホストへ同期する例
rsync -a --delete /srv/rustfs/data/ backup-host:/backup/rustfs/data/

# S3 レベルで別ストレージへ同期する例
aws --endpoint-url http://localhost:9000 s3 sync s3://my-bucket s3://backup-bucket \
    --profile backup-target
```

## ログ

| 対象 | 場所 |
| --- | --- |
| RustFS のログファイル | `$RUSTFS_LOGS_DIR`（既定 `/srv/rustfs/logs/`） |
| コンテナの標準出力 | `docker compose logs -f <service>` |
| 外部リバースプロキシのアクセスログ | プロキシ側の設定・保管先を参照（本リポジトリの管轄外） |
| 収集されたログ | 別リポジトリ kjlb-observability-stack の Grafana → Explore → Loki データソース |

ログレベルは compose.yaml の `RUSTFS_OBS_LOGGER_LEVEL` で変更する
（`info` / `debug` など）。

## 監視

Grafana / Prometheus / Tempo / Loki による監視は別リポジトリ
[kjlb-observability-stack](../../kjlb-observability-stack) に分離してある。
本リポジトリとの連携ポイントは `.env` の `RUSTFS_OBS_ENDPOINT`（OTLP 送信先）のみ。

```
rustfs --OTLP (ホスト経由)--> otel-collector --+--> tempo      (トレース)
                                                +--> prometheus (メトリクス)
                                                +--> loki       (ログ)
                                                        │
                                                     grafana
```

`.env` に `RUSTFS_OBS_ENDPOINT=http://host.docker.internal:4318` を設定していないと
テレメトリは送信されない。監視スタックを起動しない構成では未設定のままにする。

監視スタック側の設定ファイル・ダッシュボード・運用手順は
kjlb-observability-stack リポジトリの `docs/operations.md` を参照。

## バージョン更新

イメージのバージョンは compose.yaml に固定してある。更新するときは
タグを書き換えてから起動しなおす。

```sh
docker compose pull
docker compose up -d
```

RustFS は現在 1.0.0 のベータ版しかリリースされていない。
更新前にバックアップを取ること。

## SNMD への移行

将来 1ノード複数ディスク（SNMD）に拡張する場合。

1. ホスト側で各物理ディスクを `$RUSTFS_DATA_DIR/rustfs0` 〜 `rustfs3` にマウント
2. compose.yaml の `RUSTFS_VOLUMES` を `/data/rustfs{0...3}` に変更
3. 再起動

bind mount は `$RUSTFS_DATA_DIR` ごと渡しているため、compose.yaml の
volumes 定義は変更不要。パーミッション調整も
`volume-permission-helper` が再帰的に処理する。

既存データの移行が必要になるため、事前にバックアップを取ること。

## トラブルシューティング

### SignatureDoesNotMatch

| 原因 | 確認 |
| --- | --- |
| path-style を指定していない | クライアント設定を確認（[usage.md](usage.md)） |
| リージョンの不一致 | クライアント側のリージョン設定 |
| アクセスキー／シークレットキーの誤り | `.env` と照合 |
| 外部リバースプロキシの設定変更 | 上記「リバースプロキシを構成する際の注意」を確認 |
| クライアントとサーバーの時刻ずれ | 15 分以上ずれると署名が無効になる。NTP を確認 |

### 外部からアクセスできない

rustfs コンテナがホストへポートを公開しているか確認する。外部から
アクセスする場合は、別途用意するリバースプロキシがこれらのポートへ
到達できているかも確認する。

```sh
docker ps --format '{{.Names}}\t{{.Ports}}'
# rustfs-server に 0.0.0.0:9000->9000/tcp, 0.0.0.0:9001->9001/tcp があること
```

### rustfs が起動しない / パーミッションエラー

`volume-permission-helper` が正常終了しているか確認する。

```sh
docker compose logs volume-permission-helper
ls -la "$(grep RUSTFS_DATA_DIR .env | cut -d= -f2)"
# 10001:10001 所有であること
```

### Grafana / Prometheus に接続できない

別リポジトリ kjlb-observability-stack を起動していない可能性が高い。
そちらのリポジトリで `make up` を実行する。

### 監視にデータが出ない

`.env` の `RUSTFS_OBS_ENDPOINT` が設定されているか、kjlb-observability-stack が
起動しているか確認する。設定を追加した場合は rustfs の再作成が必要。

```sh
docker compose up -d --force-recreate rustfs
```
