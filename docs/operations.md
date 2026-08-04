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

docker compose --profile proxy --profile observability up -d
```

`make setup` と `make up-all` でも同じことができる。

### .env の項目

全項目の説明は `.env.example` にある。要点は以下。

| 変数 | 未設定時 | 備考 |
| --- | --- | --- |
| `RUSTFS_ACCESS_KEY` | `rustfsadmin` | **必ず設定する**（既定値は公知） |
| `RUSTFS_SECRET_KEY` | `rustfsadmin` | **必ず設定する**。32文字以上を推奨 |
| `GRAFANA_ADMIN_USER` | `admin` | |
| `GRAFANA_ADMIN_PASSWORD` | `admin` | **必ず設定する** |
| `RUSTFS_OBS_ENDPOINT` | 空（送信しない） | 監視を使うなら `http://otel-collector:4318` |
| `GRAFANA_ROOT_URL` | `http://localhost/grafana/` | 外部から見えるURLに合わせる |
| `PROMETHEUS_EXTERNAL_URL` | `http://localhost/prometheus/` | 同上 |
| `NGINX_HTTP_PORT` | `80` | 変更時はクライアントのエンドポイントURLにもポートを含める |
| `NGINX_HTTPS_PORT` | `443` | 同上 |
| `RUSTFS_DATA_DIR` | `/srv/rustfs/data` | オブジェクトデータの保存先（ホスト側） |
| `RUSTFS_LOGS_DIR` | `/srv/rustfs/logs` | ログの保存先（ホスト側） |

`.env` を変更したら、コンテナを再作成しないと反映されない。

```sh
make up-all   # 変更のあったサービスだけ再作成される
```

ディレクトリの所有者は `volume-permission-helper` が起動時に
RustFS の実行ユーザ (10001:10001) へ変更するため、手動の chown は不要。

## 起動と停止

profile でサービス群を切り替える。

| profile | サービス |
| --- | --- |
| （なし） | rustfs, volume-permission-helper |
| `proxy` | nginx |
| `observability` | otel-collector, prometheus, tempo, loki, grafana |

Makefile に主要な操作をまとめてある（`make` で一覧）。
以下は同等の docker compose コマンド。

| make | docker compose |
| --- | --- |
| `make up` | `docker compose --profile proxy up -d` |
| `make up-all` | `docker compose --profile proxy --profile observability up -d` |
| `make down` | `docker compose --profile proxy --profile observability down` |
| `make ps` | `... ps` |
| `make logs S=rustfs` | `... logs -f rustfs` |

```sh
# 通常運用
docker compose --profile proxy up -d

# 監視込み
docker compose --profile proxy --profile observability up -d

# 停止
docker compose --profile proxy --profile observability down

# 状態確認
docker compose --profile proxy --profile observability ps
```

**`--profile proxy` は必須。** rustfs はホストにポートを公開しておらず、
nginx 経由でしかアクセスできないため、付け忘れると外部から到達できない。

`down -v` は監視スタックの named volume（Prometheus / Grafana / Tempo / Loki の
データ）を削除する。オブジェクトデータは `/srv/rustfs/` の bind mount なので
`down -v` では消えない。

## ネットワーク境界

ホストに公開しているポートは **nginx の 80 / 443 のみ**。
他のサービスはすべて Docker ネットワーク内に閉じている。

```
        外部
         │  80 / 443
    ┌────▼─────┐
    │  nginx   │
    └────┬─────┘
         │  /              → rustfs:9000  (S3 API)
         │  /rustfs/console → rustfs:9001  (コンソール)
         │  /grafana/       → grafana:3000
         │  /prometheus/    → prometheus:9090
```

Prometheus は認証機構を持たないため、公開環境では nginx の `/prometheus/`
ブロックにある `allow` / `deny` のコメントを外して接続元を制限すること。

Tempo / Loki / otel-collector には外部からの入口を用意していない。
参照は Grafana 経由で行う。ホスト外のアプリからも OTLP でテレメトリを
送りたい場合のみ、otel-collector に `ports:` で 4317 / 4318 を公開する。

## URL 一覧

| URL | 内容 |
| --- | --- |
| `/` | S3 API |
| `/rustfs/console` | RustFS コンソール |
| `/grafana/` | Grafana（ダッシュボード 7 種を自動プロビジョニング） |
| `/prometheus/` | Prometheus |

## TLS

1. 証明書と鍵を `.docker/nginx/ssl/` に配置する
2. `.docker/nginx/nginx.conf` の 443 サーバーブロックのコメントを外し、
   `server_name` を実際のホスト名にする
3. 80 番ブロックの `return 301 https://$host$request_uri;` を有効にする
4. `.env` の `GRAFANA_ROOT_URL` / `PROMETHEUS_EXTERNAL_URL` を `https://` に変更
5. `docker compose --profile proxy up -d nginx` で反映

`server_name` は**クライアントが実際にアクセスするホスト名と一致させる**こと。
SigV4 の署名には Host ヘッダが含まれるため、ここがずれると認証が通らない。

## nginx を変更するときの注意（SigV4）

S3 の SigV4 署名は **HTTP メソッド・リクエストパス・Host ヘッダ**を
署名計算に含む。プロキシがこれらを書き換えると `SignatureDoesNotMatch` になる。

nginx.conf を編集する際は以下を壊さないこと。

| 守ること | 理由 |
| --- | --- |
| S3 API は `location /` のまま | サブパス配信は署名を壊す。先頭セグメントはバケット名でもある |
| `proxy_pass http://rustfs_s3;` に URI を付けない | URI を付けると nginx がパスを正規化し、記号や日本語を含むキーで署名が壊れる |
| `rewrite` や正規表現 location を使わない | 同上 |
| `proxy_set_header Host $http_host;` | `$host` はポート番号を落とすため署名と食い違う |
| `proxy_cache_convert_head off;` | nginx はキャッシュ有効時 HEAD を GET に変換する。メソッドが変わると署名が壊れる |

変更後は必ず以下で疎通確認する。

```sh
make nginx-reload   # 構文チェックしてから再読込
make s3-check       # 署名・HEAD・特殊文字キーの疎通確認
```

`/grafana/` と `/prometheus/` は S3 ではないので、これらの制約は適用されない。

## バックアップ

SNSD 構成には冗長性が無い。ディスク障害＝データ損失になるため、
バックアップは必須。

```sh
# ローカルの別ディスクへ
make backup DEST=/mnt/backup/rustfs

# 別ホストへ同期する例
rsync -a --delete /srv/rustfs/data/ backup-host:/backup/rustfs/data/

# S3 レベルで別ストレージへ同期する例
aws --endpoint-url http://localhost s3 sync s3://my-bucket s3://backup-bucket \
    --profile backup-target
```

監視スタックのデータ（メトリクス・ログ・トレース）は再現可能なので、
通常はバックアップ対象に含めなくてよい。

## ログ

| 対象 | 場所 |
| --- | --- |
| RustFS のログファイル | `$RUSTFS_LOGS_DIR`（既定 `/srv/rustfs/logs/`） |
| コンテナの標準出力 | `docker compose logs -f <service>` |
| nginx アクセスログ | `docker compose logs nginx`（tmpfs のため再起動で消える） |
| 収集されたログ | Grafana → Explore → Loki データソース |

ログレベルは compose.yaml の `RUSTFS_OBS_LOGGER_LEVEL` で変更する
（`info` / `debug` など）。

## 監視

Grafana に RustFS 用ダッシュボードが 7 種プロビジョニングされている。

- RustFS（全体）
- GET Data Integrity / GET Performance Attribution / GET Resource Impact
- GET Rollout Health / Object Data Cache / PUT Performance Attribution

データソースは Prometheus（メトリクス）、Loki（ログ）、Tempo（トレース）の 3 つ。
テレメトリは rustfs → otel-collector → 各バックエンドという流れで送られる。

```
rustfs --OTLP--> otel-collector --+--> tempo      (トレース)
                                  +--> prometheus (メトリクス, 8889 を scrape)
                                  +--> loki       (ログ)
                                          │
                                       grafana
```

`.env` に `RUSTFS_OBS_ENDPOINT=http://otel-collector:4318` を設定していないと
テレメトリは送信されない。監視スタックを起動しない構成では未設定のままにする。

設定ファイルは `.docker/observability/` 配下にある。

## バージョン更新

イメージのバージョンは compose.yaml に固定してある。更新するときは
タグを書き換えてから起動しなおす。

```sh
docker compose --profile proxy --profile observability pull
docker compose --profile proxy --profile observability up -d
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
| nginx の設定変更 | 上記「nginx を変更するときの注意」を確認 |
| クライアントとサーバーの時刻ずれ | 15 分以上ずれると署名が無効になる。NTP を確認 |

### 外部からアクセスできない

`--profile proxy` を付けて起動しているか確認する。
rustfs 単体ではホストにポートを公開していない。

```sh
docker ps --format '{{.Names}}\t{{.Ports}}'
# nginx-proxy に 0.0.0.0:80->80/tcp があること
```

### rustfs が起動しない / パーミッションエラー

`volume-permission-helper` が正常終了しているか確認する。

```sh
docker compose logs volume-permission-helper
ls -la "$(grep RUSTFS_DATA_DIR .env | cut -d= -f2)"
# 10001:10001 所有であること
```

### /grafana/ が 502

`observability` profile を起動していない。

```sh
docker compose --profile proxy --profile observability up -d
```

nginx は Grafana 不在でも起動できるよう Docker 内蔵 DNS で実行時に
名前解決している。502 は異常ではなく「未起動」を意味する。

### Prometheus のターゲットが down

`/prometheus/targets` で確認する。`observability` profile 内の
サービスが起動しているか、`.docker/observability/prometheus.yml` の
ターゲット名が compose のサービス名と一致しているかを見る。

### 監視にデータが出ない

`.env` の `RUSTFS_OBS_ENDPOINT` が設定されているか確認する。
設定を追加した場合は rustfs の再作成が必要。

```sh
docker compose --profile proxy --profile observability up -d --force-recreate rustfs
```
