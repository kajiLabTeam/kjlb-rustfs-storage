# kjlb-rustfs-storage
#
# よく使う docker compose 操作をまとめたもの。
# `make` または `make help` で一覧を表示する。

COMPOSE       := docker compose
PROFILES      := --profile proxy
PROFILES_ALL  := --profile proxy --profile observability
ENV_FILE      := .env

# .env があれば読み込む（マウント先や S3 の認証情報を使う）
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

# マウント先。.env で未設定なら compose.yaml と同じ既定値を使う。
RUSTFS_DATA_DIR ?= /srv/rustfs/data
RUSTFS_LOGS_DIR ?= /srv/rustfs/logs

ENDPOINT ?= http://localhost

.DEFAULT_GOAL := help
.PHONY: help env env-check setup up up-all down down-all restart ps logs logs-rustfs health \
        config nginx-test nginx-reload pull update backup console shell \
        s3-ls s3-mb s3-check clean

## ヘルプを表示
help:
	@awk 'BEGIN{FS=":"} \
	     /^# ---/{next} \
	     /^## /{d=substr($$0,4); next} \
	     /^[a-zA-Z0-9_-]+:/{if(d!=""){printf "  \033[36m%-14s\033[0m %s\n",$$1,d; d=""}}' \
	     $(MAKEFILE_LIST)

# ---------------------------------------------------------------- セットアップ

## .env を .env.example から生成する (秘密情報は自動生成)
env:
	@test ! -f $(ENV_FILE) || { echo "!! $(ENV_FILE) は既に存在します。上書きする場合は削除してから実行してください"; exit 1; }
	@sk=$$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-40); \
	 gp=$$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24); \
	 sed -e "s|^RUSTFS_ACCESS_KEY=.*|RUSTFS_ACCESS_KEY=rustfs|" \
	     -e "s|^RUSTFS_SECRET_KEY=.*|RUSTFS_SECRET_KEY=$${sk}|" \
	     -e "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=$${gp}|" \
	     .env.example > $(ENV_FILE)
	@chmod 600 $(ENV_FILE)
	@echo "OK: $(ENV_FILE) を生成しました。内容を確認してください:"
	@grep -E '^(RUSTFS_ACCESS_KEY|RUSTFS_SECRET_KEY|GRAFANA_ADMIN_PASSWORD)=' $(ENV_FILE) | sed 's/^/  /'

## .env に不足している項目を確認する
env-check:
	@test -f $(ENV_FILE) || { echo "!! $(ENV_FILE) がありません。make env で生成してください"; exit 1; }
	@awk -F= '\
	  /^RUSTFS_ACCESS_KEY=/      {v[$$1]=$$2} \
	  /^RUSTFS_SECRET_KEY=/      {v[$$1]=$$2} \
	  /^GRAFANA_ADMIN_PASSWORD=/ {v[$$1]=$$2} \
	  END { \
	    ng=0; \
	    split("RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY GRAFANA_ADMIN_PASSWORD", k, " "); \
	    for (i in k) if (v[k[i]] == "") { printf "  未設定: %s\n", k[i]; ng=1 } \
	    if (v["RUSTFS_SECRET_KEY"] != "" && length(v["RUSTFS_SECRET_KEY"]) < 32) { \
	      printf "  警告: RUSTFS_SECRET_KEY が %d 文字です (32文字以上を推奨)\n", \
	             length(v["RUSTFS_SECRET_KEY"]); ng=1 } \
	    if (v["GRAFANA_ADMIN_PASSWORD"] == "admin") { \
	      print "  警告: GRAFANA_ADMIN_PASSWORD が既定値のままです"; ng=1 } \
	    if (ng == 0) print "$(ENV_FILE) OK" \
	  }' $(ENV_FILE)

## データディレクトリを作成する (書き込めない場所なら sudo を使う)
setup:
	@for d in "$(RUSTFS_DATA_DIR)" "$(RUSTFS_LOGS_DIR)"; do \
	  if mkdir -p "$$d" 2>/dev/null; then echo "  作成: $$d"; \
	  else echo "  作成 (sudo): $$d"; sudo mkdir -p "$$d" || exit 1; fi; \
	done
	@test -f $(ENV_FILE) || { \
	  echo "!! $(ENV_FILE) がありません。以下を作成してください:"; \
	  echo "   RUSTFS_ACCESS_KEY=..."; \
	  echo "   RUSTFS_SECRET_KEY=..."; \
	  echo "   GRAFANA_ADMIN_PASSWORD=..."; \
	  exit 1; \
	}
	@echo "OK: $(RUSTFS_DATA_DIR) と $(RUSTFS_LOGS_DIR) を作成しました"

# ------------------------------------------------------------------ 起動・停止

## 起動する (rustfs + nginx)
up:
	$(COMPOSE) $(PROFILES) up -d

## 監視スタック込みで起動する
up-all:
	$(COMPOSE) $(PROFILES_ALL) up -d

## 停止する
down:
	$(COMPOSE) $(PROFILES_ALL) down

## 停止し監視データも削除する (オブジェクトデータは残る)
down-all:
	$(COMPOSE) $(PROFILES_ALL) down -v

## 再起動する
restart:
	$(COMPOSE) $(PROFILES_ALL) restart

# ---------------------------------------------------------------------- 状態

## コンテナの状態を表示する
ps:
	@$(COMPOSE) $(PROFILES_ALL) ps

## ログを追う (S=サービス名 で絞り込み)
logs:
	$(COMPOSE) $(PROFILES_ALL) logs -f --tail=100 $(S)

## rustfs のログを追う
logs-rustfs:
	$(COMPOSE) logs -f --tail=100 rustfs

## 各エンドポイントの疎通を確認する
health:
	@for e in "S3 API|/|403=正常" \
	          "コンソール|/rustfs/console|" \
	          "Grafana|/grafana/|502=observability未起動" \
	          "Prometheus|/prometheus/|502=observability未起動"; do \
	  name=$${e%%|*}; rest=$${e#*|}; path=$${rest%%|*}; note=$${rest#*|}; \
	  code=$$(curl -sL -o /dev/null -w '%{http_code}' "$(ENDPOINT)$${path}" 2>/dev/null); \
	  case "$${code}" in ""|000) code="接続不可"; note="未起動?";; \
	    $${note%%=*}) note="$${note#*=}";; *) note="";; esac; \
	  printf '  %-12s %-9s %s\n' "$${name}" "$${code}" "$${note}"; \
	done
	@echo "--- 公開ポート (nginx の 80/443 のみが正常) ---"
	@docker ps --format '  {{.Names}}\t{{.Ports}}' | grep -E 'rustfs|nginx|grafana|prometheus|tempo|loki|otel' || echo "  (起動中のコンテナなし)"

# ------------------------------------------------------------------- 設定確認

## compose.yaml の構文を検証する
config:
	@$(COMPOSE) $(PROFILES_ALL) config -q && echo "compose.yaml OK"

## nginx.conf の構文を検証する (nginx 起動中のみ)
nginx-test:
	$(COMPOSE) exec nginx nginx -t

## nginx.conf の変更を反映する
nginx-reload: nginx-test
	$(COMPOSE) exec nginx nginx -s reload
	@echo "nginx を再読込しました"

# --------------------------------------------------------------------- 更新

## イメージを取得する
pull:
	$(COMPOSE) $(PROFILES_ALL) pull

## イメージを取得して再起動する
update: pull up-all

# ------------------------------------------------------------------- 運用補助

## オブジェクトデータをバックアップする (DEST=/path/to/backup)
backup:
	@test -n "$(DEST)" || { echo "使い方: make backup DEST=/path/to/backup"; exit 1; }
	rsync -a --delete $(RUSTFS_DATA_DIR)/ $(DEST)/
	@echo "OK: $(DEST) へバックアップしました"

## コンソールの URL を表示する
console:
	@echo "$(ENDPOINT)/rustfs/console"

## rustfs コンテナにシェルで入る
shell:
	$(COMPOSE) exec rustfs sh

# ---------------------------------------------------------------- S3 操作補助
# .env の認証情報を使い、コンテナ内の aws-cli で実行する

AWS = docker run --rm --network kjlb-rustfs-storage_rustfs-network \
        -e AWS_ACCESS_KEY_ID=$(RUSTFS_ACCESS_KEY) \
        -e AWS_SECRET_ACCESS_KEY=$(RUSTFS_SECRET_KEY) \
        -e AWS_DEFAULT_REGION=us-east-1 \
        amazon/aws-cli:latest --endpoint-url http://nginx

## バケット一覧を表示する
s3-ls:
	@$(AWS) s3 ls

## バケットを作成する (B=バケット名)
s3-mb:
	@test -n "$(B)" || { echo "使い方: make s3-mb B=bucket-name"; exit 1; }
	@case "$(B)" in rustfs|grafana|prometheus) \
	  echo "!! '$(B)' は nginx の location と衝突するため使用できません"; exit 1;; esac
	@$(AWS) s3 mb s3://$(B)

## S3 の疎通を確認する (署名・HEAD・特殊文字キー)
s3-check:
	@$(AWS) s3api create-bucket --bucket makecheck >/dev/null 2>&1 || true
	@$(AWS) s3api list-buckets --query 'Buckets[].Name' >/dev/null && echo "  署名(SigV4)  OK"
	@docker run --rm --network kjlb-rustfs-storage_rustfs-network \
	  -e AWS_ACCESS_KEY_ID=$(RUSTFS_ACCESS_KEY) \
	  -e AWS_SECRET_ACCESS_KEY=$(RUSTFS_SECRET_KEY) \
	  -e AWS_DEFAULT_REGION=us-east-1 --entrypoint sh amazon/aws-cli:latest -c ' \
	    A="aws --endpoint-url http://nginx"; \
	    echo test > /tmp/t.txt; \
	    $$A s3api put-object --bucket makecheck --key "a b/日本語 +file.txt" --body /tmp/t.txt >/dev/null \
	      && echo "  特殊文字キー OK"; \
	    $$A s3api head-object --bucket makecheck --key "a b/日本語 +file.txt" >/dev/null \
	      && echo "  HEAD         OK"; \
	    $$A s3api delete-object --bucket makecheck --key "a b/日本語 +file.txt" >/dev/null; \
	  '
	@$(AWS) s3 rb s3://makecheck >/dev/null 2>&1 || true

# ---------------------------------------------------------------------- 掃除

## 停止して未使用イメージを削除する
clean: down
	docker image prune -f
