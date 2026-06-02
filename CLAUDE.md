# CLAUDE.md — Home Smart Factory

## プロジェクト概要

Raspberry PiのセンサーデータをAWS IoT Core経由で収集し、ECS上のWorker/Batch/BackendアプリとRDSで処理・蓄積するIoT設備監視基盤。
異常検知・日次レポート自動生成・Grafana/Reactによるデータ可視化を提供する。

## 技術スタック

- **IaC**: Terraform ~> 1.15.0
- **クラウド**: AWS ap-northeast-1（AWSプロバイダー ~> 6.0）
- **状態管理**: S3（リモートバックエンド、暗号化有効、DynamoDBロックなし）

---

## 主要設計ドキュメント

| ドキュメント | パス |
|---|---|
| 機能要件 | [docs/spec-requirements/functional-requirements.md](docs/spec-requirements/functional-requirements.md) |
| 非機能要件 | [docs/spec-requirements/non-functional-requirements.md](docs/spec-requirements/non-functional-requirements.md) |
| システム構成図 | [docs/basic-design/system-architecture.md](docs/basic-design/system-architecture.md) |
| API設計書 | [docs/basic-design/api-design.md](docs/basic-design/api-design.md) |
| DB設計書 | [docs/basic-design/db-design.md](docs/basic-design/db-design.md) |
| インフラ定義書 | [docs/basic-design/infrastructure-design.md](docs/basic-design/infrastructure-design.md) |
| IoTメッセージ形式 | [docs/detailed-design/iot-message-format.md](docs/detailed-design/iot-message-format.md) |
| ECS Worker/Batch ロジック | [docs/detailed-design/ecs-worker-batch-logic.md](docs/detailed-design/ecs-worker-batch-logic.md) |
| 画面設計書 | [docs/detailed-design/wireframe-design.md](docs/detailed-design/wireframe-design.md) |
| Grafanaダッシュボード設計 | [docs/detailed-design/grafana-dashboard-design.md](docs/detailed-design/grafana-dashboard-design.md) |

---

## Terraformディレクトリ構造

- `envs/prod/` — 本番環境ルートモジュール
- `envs/prod/versions.tf` — Terraform・プロバイダーバージョン固定、S3バックエンド設定
- `envs/prod/locals.tf` — 共通タグ・名前プレフィックス
- `envs/prod/variables.tf` — 入力変数
- `envs/prod/main.tf` — モジュール呼び出し
- `envs/prod/outputs.tf` — 出力値
- `envs/prod/tests/` — terraform test ファイル（`*.tftest.hcl`）
- `modules/<name>/main.tf` — リソース定義
- `modules/<name>/variables.tf` — 入力変数
- `modules/<name>/outputs.tf` — 出力値
- モジュール一覧: `vpc` / `iam` / `ecr` / `rds` / `elasticache` / `sqs` / `sns` / `iot` / `alb` / `ecs` / `lambda` / `eventbridge` / `cloudwatch`

## 行動規範

### 基本的な行動規範
- 3ステップ以上のタスクは必ずPlanモードで開始する
- 変更は必要な箇所のみ。影響範囲を最小化する

### コンテキスト圧迫時の行動規範（焦ったら止まれ）
- コードを読まずに書かない
- 検証を省略しない
- Planモードを飛ばさない
- サブエージェントを使う（コンテキスト節約）
- 中途半端に終わらせるなら止まる
- 焦りを自覚したら宣言する
