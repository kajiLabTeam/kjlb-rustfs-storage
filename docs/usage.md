# 利用ガイド

RustFS は S3 互換ストレージなので、AWS SDK / CLI がそのまま使える。
このドキュメントはアプリケーションから接続する側の手順をまとめたもの。
サーバーの構築・運用は [operations.md](operations.md) を参照。

## 接続情報

| 項目 | 値 |
| --- | --- |
| エンドポイント | `http://<ホスト>:9000/`（TLS を使う場合は外部のリバースプロキシ経由の URL） |
| アクセスキー | `.env` の `RUSTFS_ACCESS_KEY` |
| シークレットキー | `.env` の `RUSTFS_SECRET_KEY` |
| リージョン | `us-east-1`（任意の値でよいが、統一すること） |
| アドレッシング | **パス形式（path-style）** |

### 必ず path-style を指定する

AWS SDK は既定で仮想ホスト形式（`https://<バケット名>.example.com/key`）を使う。
RustFS は単一ホスト名で動くのでこの形式は解決できない。
**すべてのクライアントで path-style を明示すること。**

### リージョンについて

RustFS はリージョンを検証しないが、SigV4 の署名計算にはリージョン名が含まれる。
クライアントとサーバーで食い違うと `SignatureDoesNotMatch` になるため、
アプリケーション間で値を統一しておく。以下の例では `us-east-1` を使う。

## AWS CLI

```sh
aws configure set aws_access_key_id     <ACCESS_KEY>
aws configure set aws_secret_access_key <SECRET_KEY>
aws configure set region                us-east-1
# path-style を既定にする
aws configure set s3.addressing_style   path
```

以降 `--endpoint-url` を付けて実行する。

```sh
EP=http://storage.example.com:9000

# バケット
aws --endpoint-url $EP s3 mb s3://my-bucket
aws --endpoint-url $EP s3 ls

# アップロード / ダウンロード
aws --endpoint-url $EP s3 cp ./local.txt s3://my-bucket/path/local.txt
aws --endpoint-url $EP s3 cp s3://my-bucket/path/local.txt ./
aws --endpoint-url $EP s3 sync ./dir s3://my-bucket/dir/

# 一覧・削除
aws --endpoint-url $EP s3 ls s3://my-bucket/path/
aws --endpoint-url $EP s3 rm s3://my-bucket/path/local.txt

# メタデータのみ取得
aws --endpoint-url $EP s3api head-object --bucket my-bucket --key path/local.txt
```

毎回 `--endpoint-url` を書くのが面倒なら環境変数でもよい。

```sh
export AWS_ENDPOINT_URL=http://storage.example.com:9000
```

## Python (boto3)

```python
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url="http://storage.example.com:9000",
    aws_access_key_id="<ACCESS_KEY>",
    aws_secret_access_key="<SECRET_KEY>",
    region_name="us-east-1",
    config=Config(
        # 必須。これが無いと <bucket>.storage.example.com を引きにいって失敗する
        s3={"addressing_style": "path"},
        signature_version="s3v4",
        retries={"max_attempts": 3, "mode": "standard"},
    ),
)

s3.create_bucket(Bucket="my-bucket")
s3.upload_file("local.txt", "my-bucket", "path/local.txt")
s3.download_file("my-bucket", "path/local.txt", "downloaded.txt")

for obj in s3.list_objects_v2(Bucket="my-bucket").get("Contents", []):
    print(obj["Key"], obj["Size"])
```

### 署名付き URL

一時的なダウンロード／アップロード URL を発行できる。
発行された URL のホスト名は `endpoint_url` のものになるため、
クライアントから到達可能なホスト名を設定しておくこと。

```python
url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": "my-bucket", "Key": "path/local.txt"},
    ExpiresIn=3600,
)
```

## PHP (AWS SDK for PHP)

```php
$s3 = new Aws\S3\S3Client([
    'version'                 => 'latest',
    'region'                  => 'us-east-1',
    'endpoint'                => 'http://storage.example.com:9000',
    'use_path_style_endpoint' => true,   // 必須
    'credentials'             => [
        'key'    => getenv('S3_ACCESS_KEY'),
        'secret' => getenv('S3_SECRET_KEY'),
    ],
]);

$s3->putObject([
    'Bucket'     => 'my-bucket',
    'Key'        => 'path/local.txt',
    'SourceFile' => '/tmp/local.txt',
]);
```

## Go (aws-sdk-go-v2)

```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithRegion("us-east-1"),
    config.WithCredentialsProvider(
        credentials.NewStaticCredentialsProvider(accessKey, secretKey, "")),
)

client := s3.NewFromConfig(cfg, func(o *s3.Options) {
    o.BaseEndpoint = aws.String("http://storage.example.com:9000")
    o.UsePathStyle = true // 必須
})
```

## Web ブラウザからの利用（CORS）

ブラウザの JavaScript から直接 RustFS を叩く場合、CORS 設定が要る。
現在の構成では S3 API 側の CORS は設定していないため、
必要になったらバケットの CORS 設定を追加する。

```sh
aws --endpoint-url $EP s3api put-bucket-cors --bucket my-bucket \
  --cors-configuration '{
    "CORSRules": [{
      "AllowedOrigins": ["https://app.example.com"],
      "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    }]
  }'
```

なお署名付き URL を使ってサーバー側で発行する方式にすれば、
ブラウザに認証情報を渡さずに済むのでそちらを推奨する。

## Web コンソール

http://\<ホスト\>:9001/rustfs/console

アクセスキー／シークレットキーでログインし、バケットとオブジェクトを
GUI で操作できる。

## 制約と注意点

### サブパスでの配信は不可

`https://example.com/s3/` のような形で S3 API を配信することはできない。
SigV4 署名がパスを含むため壊れる。詳細は [operations.md](operations.md) の
SigV4 の節を参照。ホスト名を分ける（`s3.example.com`）のは問題ない。
外部にリバースプロキシを立てる場合も同様の制約を守る必要がある。

### 単一ノード構成

現在は SNSD（1ノード1ディスク）構成のため、**冗長性が無い**。
ディスク障害はデータ損失に直結する。重要なデータは別途バックアップすること。

### 大容量ファイル

100MB を超えるファイルは SDK のマルチパートアップロードが自動的に使われる。
本リポジトリの構成自体にリクエストサイズ制限は無い。外部にリバースプロキシを
置く場合は、そちら側のリクエストサイズ上限に注意すること。
