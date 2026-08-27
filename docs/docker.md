# .docker/ 配下の構成

本リポジトリはもはや監視スタック（Grafana / Prometheus / Tempo / Loki /
otel-collector）を同梱していない。それらの設定ファイルとドキュメントは
別リポジトリ [kjlb-observability-stack](../../kjlb-observability-stack)
（パス: `/Users/shika_san/Development/KJLB/kjlb-observability-stack`）に
移動した。設定ファイルの役割については、そちらのリポジトリの
`.docker/observability/` 配下および `docs/operations.md` を参照。

本リポジトリの `.docker/` には現在、rustfs 固有の設定ファイルは無い
（rustfs はコンテナの環境変数のみで設定する）。
