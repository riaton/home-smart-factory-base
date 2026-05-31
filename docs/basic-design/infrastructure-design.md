# インフラ定義書

## Home Smart Factory -- IoT設備監視基盤

------------------------------------------------------------------------

# 1. 概要

本書はHome Smart FactoryシステムのAWSインフラ構成・設定値・運用方針を定義する。

| 項目 | 内容 |
|---|---|
| クラウド | AWS |
| リージョン | ap-northeast-1（東京） |
| 環境 | 本番環境（単一環境。開発環境は本番と同アカウントで分離しない） |
| デプロイ方式 | Terraform |

------------------------------------------------------------------------

# 2. ネットワーク（VPC）

## 2.1 VPC構成

| 項目 | 値 |
|---|---|
| VPC CIDR | 10.0.0.0/16 |
| AZ | ap-northeast-1a / ap-northeast-1c（2AZ構成） |

## 2.2 サブネット

| サブネット名 | CIDR | 種別 | 用途 |
|---|---|---|---|
| public-1a | 10.0.1.0/24 | パブリック | ALB、Grafana |
| public-1c | 10.0.2.0/24 | パブリック | ALB |
| private-1a | 10.0.11.0/24 | プライベート | ECS（Worker/Batch/Backend）、RDS、ElastiCache |
| private-1c | 10.0.12.0/24 | プライベート | ECS（Backend）、RDS |

## 2.3 セキュリティグループ

| SG名 | インバウンド | アウトバウンド | 用途 |
|---|---|---|---|
| sg-alb | 443（HTTPS）from 0.0.0.0/0 | ECS Backend へ 8080 | ALB |
| sg-ecs-backend | 8080 from sg-alb | RDS:5432、Redis:6379、HTTPS 443 | ECS Backend |
| sg-ecs-worker | なし（アウトバウンドのみ） | RDS:5432、SQS・SNS（VPCエンドポイント経由） | ECS Worker |
| sg-ecs-batch | なし（アウトバウンドのみ） | RDS:5432 | ECS Batch |
| sg-rds | 5432 from sg-ecs-backend / sg-ecs-worker / sg-ecs-batch / sg-grafana | なし | RDS PostgreSQL |
| sg-redis | 6379 from sg-ecs-backend | なし | ElastiCache Redis |
| sg-grafana | 3000 from 管理者IPのみ | RDS:5432 | Grafana |

## 2.4 VPCエンドポイント

SQS・SNS・CloudWatch Logs・ECR への通信はVPCエンドポイント（インターフェース型）を使用し、インターネットを経由しない。

| エンドポイント | 種別 |
|---|---|
| com.amazonaws.ap-northeast-1.sqs | Interface |
| com.amazonaws.ap-northeast-1.sns | Interface |
| com.amazonaws.ap-northeast-1.logs | Interface |
| com.amazonaws.ap-northeast-1.ecr.api | Interface |
| com.amazonaws.ap-northeast-1.ecr.dkr | Interface |
| com.amazonaws.ap-northeast-1.s3 | Gateway |

------------------------------------------------------------------------

# 3. AWS IoT Core

## 3.1 概要

Raspberry Pi（Java Collector）からのMQTTメッセージを受信し、IoT Ruleで Amazon SQS へ転送する。

## 3.2 MQTT設定

| 項目 | 値 |
|---|---|
| プロトコル | MQTT over TLS（ポート 8883） |
| 認証方式 | X.509クライアント証明書 |
| QoS | 1（PUBACK による到達確認） |
| トピック | `home/devices/{device_id}/data` |

## 3.3 IoT ポリシー

デバイスに付与するIoTポリシー。最小権限原則に基づき Publish のみ許可。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iot:Connect",
      "Resource": "arn:aws:iot:ap-northeast-1:{ACCOUNT_ID}:client/${iot:Connection.Thing.ThingName}"
    },
    {
      "Effect": "Allow",
      "Action": "iot:Publish",
      "Resource": "arn:aws:iot:ap-northeast-1:{ACCOUNT_ID}:topic/home/devices/${iot:Connection.Thing.ThingName}/data"
    }
  ]
}
```

## 3.4 IoT Rule（SQS転送ルール）

| 項目 | 値 |
|---|---|
| ルール名 | `iot_to_sqs_rule` |
| SQL | `SELECT * FROM 'home/devices/+/data'` |
| アクション | SQS へ SendMessage（メインキュー） |
| エラーアクション | CloudWatch Logs へ記録（ロググループ: `/aws/iotcore/rule-errors`） |

転送失敗ログは CloudWatch Alarm（`iot-rule-error-alarm`、セクション11参照）で検知し、SNS トピック `cloudwatch-alarms` 経由で通知する。

------------------------------------------------------------------------

# 4. Amazon SQS

## 4.1 メインキュー

| 項目 | 値 | 備考 |
|---|---|---|
| キュー名 | `iot-data-queue` | スタンダードキュー |
| メッセージ保持期間 | 4日（345,600秒） | IoTデータは1分単位のため長期保持不要 |
| 最大メッセージサイズ | 256 KB | デフォルト |
| VisibilityTimeout | 30秒 | Workerの処理時間（INSERT + 閾値チェック）を考慮 |
| 受信待機時間（ロングポーリング） | 20秒（WaitTimeSeconds） | Worker側の設定値 |
| Dead Letter Queue | `iot-data-dlq` | 下記参照 |
| maxReceiveCount | 3 | 3回受信失敗でDLQへ移動 |

**VisibilityTimeout の根拠:**
- RDS INSERT + 閾値チェック ≒ 5秒、SNS Publish（リトライ最大3回: 1s→2s→4s）≒ 7秒、合計最大 ≒ 12秒
- 余裕を持たせて 30秒に設定（最大処理時間の約2.5倍）
- Workerがクラッシュした場合、30秒後にキューへ戻り ECS自動復旧後のWorkerが再受信できる

## 4.2 Dead Letter Queue（DLQ）

| 項目 | 値 | 備考 |
|---|---|---|
| キュー名 | `iot-data-dlq` | スタンダードキュー |
| メッセージ保持期間 | 14日（1,209,600秒） | 調査・リドライブに十分な期間 |
| VisibilityTimeout | 30秒 | メインキューと同値 |

**DLQへ移動するケース:**
- RDS一時障害が継続し maxReceiveCount（3回）を超えた場合
- データバリデーションエラー（不正なJSONペイロード等）で処理不可能なメッセージ

## 4.3 DLQ 運用方針

### 検知
DLQへメッセージが到達すると CloudWatch Alarm（後述）でアラームが発火し、運用担当者へメール通知される。

### 調査手順

1. **メッセージ内容の確認**
   ```bash
   aws sqs receive-message \
     --queue-url https://sqs.ap-northeast-1.amazonaws.com/{ACCOUNT_ID}/iot-data-dlq \
     --max-number-of-messages 10 \
     --attribute-names All
   ```

2. **CloudWatch Logs でエラーログを確認**
   ```
   ロググループ: /ecs/home-smart-factory/worker
   フィルター: ERROR
   ```

3. **原因の特定**
   - RDS接続エラーの場合 → RDS 障害状況を確認し復旧後にリドライブ
   - JSONパースエラーの場合 → Raspberry Pi 側のペイロード形式を確認

### 手動リドライブ手順

RDS復旧後など、再処理可能と判断した場合に実施する。

```bash
# DLQのメッセージをメインキューへ移動（AWS CLI v2）
aws sqs start-message-move-task \
  --source-arn arn:aws:sqs:ap-northeast-1:{ACCOUNT_ID}:iot-data-dlq \
  --destination-arn arn:aws:sqs:ap-northeast-1:{ACCOUNT_ID}:iot-data-queue \
  --max-number-of-messages-per-second 10
```

再処理不可能なメッセージ（不正ペイロード等）は手動で削除する。

```bash
aws sqs delete-message \
  --queue-url https://sqs.ap-northeast-1.amazonaws.com/{ACCOUNT_ID}/iot-data-dlq \
  --receipt-handle {RECEIPT_HANDLE}
```

------------------------------------------------------------------------

# 5. Amazon ECS

## 5.1 クラスター設定

| 項目 | 値 |
|---|---|
| クラスター名 | `home-smart-factory` |
| 起動タイプ | Fargate |
| Container Insights | 有効 |

## 5.2 共通タスク定義設定（CloudWatch Logs）

全ECSタスクに共通で以下の `logConfiguration` を設定する。

```json
{
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/ecs/home-smart-factory/{service-name}",
      "awslogs-region": "ap-northeast-1",
      "awslogs-stream-prefix": "ecs"
    }
  }
}
```

| サービス名 | ロググループ |
|---|---|
| Worker | `/ecs/home-smart-factory/worker` |
| Batch | `/ecs/home-smart-factory/batch` |
| Backend | `/ecs/home-smart-factory/backend` |
| Grafana | `/ecs/home-smart-factory/grafana` |

**ログ保持期間:** 全ロググループとも 365日（非機能要件 E.7.1.2 に基づく）

## 5.3 データ処理ワーカー（Worker）

IoTデータをSQSから受信し、RDSへ保存・閾値チェック・SNS通知を行う常駐プロセス。

| 項目 | 値 |
|---|---|
| タスク定義名 | `home-smart-factory-worker` |
| サービス名 | `worker` |
| CPU | 256（0.25 vCPU） |
| メモリ | 512 MB |
| ネットワークモード | awsvpc |
| サブネット | private-1a / private-1c |
| SQSポーリング | ロングポーリング（WaitTimeSeconds=20） |
| IAMタスクロール | `ecs-worker-task-role`（後述） |

**Auto Scaling（Application Auto Scaling）:**

| 項目 | 値 |
|---|---|
| 最小タスク数 | 1 |
| 最大タスク数 | 2 |
| スケールアウト条件 | `ApproximateNumberOfMessagesVisible` ≥ 100 が 2分間継続 → +1タスク |
| スケールイン条件 | `ApproximateNumberOfMessagesVisible` < 10 が 5分間継続 → -1タスク |

## 5.4 日次レポートバッチ（Batch）

毎日 03:00 JST（18:00 UTC）に EventBridge により起動する単発タスク。

| 項目 | 値 |
|---|---|
| タスク定義名 | `home-smart-factory-batch` |
| CPU | 512（0.5 vCPU） |
| メモリ | 1024 MB |
| ネットワークモード | awsvpc |
| サブネット | private-1a |
| IAMタスクロール | `ecs-batch-task-role`（後述） |

**処理内容:**
1. 前日 00:00〜23:59 JST の iot_data を集計し daily_reports へ INSERT
2. 90日を超えた iot_data を削除（定期クリーンアップ）
3. 1年を超えた anomaly_logs / daily_reports / report_downloads を削除

## 5.5 バックエンド（Backend）

REST API サーバー。ALB 経由でフロントエンドからのリクエストを処理する。

| 項目 | 値 |
|---|---|
| タスク定義名 | `home-smart-factory-backend` |
| サービス名 | `backend` |
| CPU | 512（0.5 vCPU） |
| メモリ | 1024 MB |
| ネットワークモード | awsvpc |
| リスニングポート | 8080 |
| サブネット | private-1a / private-1c |
| IAMタスクロール | `ecs-backend-task-role`（後述） |

**Auto Scaling（Application Auto Scaling）:**

| 項目 | 値 |
|---|---|
| 最小タスク数 | 1 |
| 最大タスク数 | 2 |
| スケールアウト条件 | ECS サービス CPU使用率 ≥ 70% が 3分間継続 → +1タスク |
| スケールイン条件 | ECS サービス CPU使用率 < 30% が 10分間継続 → -1タスク |

## 5.6 Grafana

設備監視ダッシュボード。管理者のみがアクセスする。パブリックサブネットにデプロイし、セキュリティグループで管理者IPのみに制限する。

| 項目 | 値 |
|---|---|
| タスク定義名 | `home-smart-factory-grafana` |
| サービス名 | `grafana` |
| タスク数 | 1（固定、Auto Scaling なし） |
| CPU | 256（0.25 vCPU） |
| メモリ | 512 MB |
| ネットワークモード | awsvpc |
| リスニングポート | 3000 |
| サブネット | public-1a（パブリックIP割り当て有効） |
| セキュリティグループ | sg-grafana |
| IAMタスクロール | `ecs-grafana-task-role`（後述） |
| コンテナイメージ | `grafana/grafana:latest`（ECRにミラー） |

**RDS接続・認証設定（Grafana環境変数）:**

| 環境変数 | 値 |
|---|---|
| `GF_SERVER_HTTP_PORT` | `3000` |
| `GF_AUTH_ANONYMOUS_ENABLED` | `false` |
| `GF_SECURITY_ADMIN_USER` | `admin` |
| `GF_SECURITY_ADMIN_PASSWORD` | AWS Secrets Manager から取得 |
| `GF_DATABASE_TYPE` | `postgres` |
| `GF_DATABASE_HOST` | RDS エンドポイント:5432 |
| `GF_DATABASE_NAME` | `home_smart_factory` |
| `GF_DATABASE_USER` | `grafana_ro`（読み取り専用DBユーザー） |
| `GF_DATABASE_PASSWORD` | AWS Secrets Manager から取得 |

> **Grafana 専用 DB ユーザー:** Grafana は RDS へ直接クエリするため、参照専用ユーザー `grafana_ro` を作成し `SELECT` のみ付与する。アプリユーザーとは分離する。
>
> **アクセス方法:** ブラウザから `http://{Grafana パブリックIP}:3000` へ直接アクセス。管理者IP以外からの接続は sg-grafana でブロックされる。管理者IPが変わった場合はSGのインバウンドルールを手動更新する。

**IAMタスクロール（ecs-grafana-task-role）:**

| 許可アクション | リソース |
|---|---|
| `secretsmanager:GetSecretValue` | Grafana用シークレット（DBパスワード・管理者パスワード） |
| `logs:CreateLogStream`, `logs:PutLogEvents` | `/ecs/home-smart-factory/grafana` |

------------------------------------------------------------------------

# 6. Amazon RDS

## 6.1 インスタンス設定

| 項目 | 値 |
|---|---|
| エンジン | PostgreSQL 16 |
| インスタンスクラス | db.t3.micro（初期） |
| ストレージ | 20 GB gp3（Auto Scaling 有効、最大 100 GB） |
| ストレージ暗号化 | 有効（AWS管理キー）（非機能要件 E.6.1.2） |
| マルチAZ | 有効（自動フェイルオーバー） |
| サブネット | private-1a / private-1c |
| セキュリティグループ | sg-rds |
| DBname | `home_smart_factory` |
| ポート | 5432 |
| タイムゾーン | UTC（アプリケーション層でJST変換） |
| 文字コード | UTF-8 |

## 6.2 バックアップ設定

| 項目 | 値 |
|---|---|
| 自動バックアップ | 有効 |
| バックアップウィンドウ | 15:00〜16:00 UTC（深夜 JST） |
| バックアップ保持期間 | 7日 |
| スナップショット（手動） | リリース前後に手動取得 |
| ポイントインタイムリカバリ | 有効（自動バックアップ保持期間内） |

## 6.3 メンテナンス設定

| 項目 | 値 |
|---|---|
| メンテナンスウィンドウ | 月曜 16:30〜17:30 UTC |
| マイナーバージョン自動アップグレード | 有効 |

## 6.4 パラメータグループ

デフォルトパラメータグループから以下を変更したカスタムパラメータグループ（`home-smart-factory-pg16`）を使用する。

| パラメータ | 設定値 | 理由 |
|---|---|---|
| `max_connections` | 100 | db.t3.micro のメモリ上限を考慮。Backend×2 + Worker×1 + Batch×1 + Grafana×1 + 余裕分 |
| `log_min_duration_statement` | 1000（ms） | 1秒超のスロークエリを CloudWatch Logs に出力して検知 |
| `log_connections` | on | 接続ログを取得し異常接続を検知 |
| `log_disconnections` | on | 切断ログを取得 |
| `timezone` | UTC | アプリケーション層でJST変換 |

------------------------------------------------------------------------

# 7. Amazon ElastiCache（Redis）

## 7.1 設定

| 項目 | 値 |
|---|---|
| エンジン | Redis 7.x |
| ノードタイプ | cache.t3.micro |
| クラスターモード | 無効（シングルノード） |
| At-Rest 暗号化 | 有効（AWS管理キー）（非機能要件 E.6.1.2） |
| In-Transit 暗号化（TLS） | 有効（接続文字列は `rediss://` を使用） |
| サブネット | private-1a |
| セキュリティグループ | sg-redis |
| ポート | 6379 |

## 7.2 セッション管理

| 項目 | 値 |
|---|---|
| キー形式 | `session:{session_id}` |
| TTL | 86400秒（24時間）。アクセスのたびに更新（スライディング） |
| 格納データ | user_id、email |

------------------------------------------------------------------------

# 8. Amazon SNS

## 8.1 SNSトピック一覧

| トピック名 | 用途 |
|---|---|
| `iot-anomaly-notification` | 異常検知時のメール通知（ECS Worker → SNS） |
| `cloudwatch-alarms` | CloudWatch Alarmからの通知（DLQ蓄積、異常検知失敗） |
| `batch-task-failure` | バッチタスク異常終了の通知（EventBridge → SNS → Lambda） |

## 8.2 iot-anomaly-notification

| 項目 | 値 |
|---|---|
| タイプ | スタンダード |
| サブスクリプション | Email（ユーザーのGoogleアカウントメールアドレス） |

**メッセージ形式（例）:**
```
件名: [異常検知] デバイス room01 - 温度異常

デバイス: room01
検知項目: temperature
設定閾値: 35.0℃（上限）
実測値: 38.2℃
検知日時: 2026-01-15 10:00:00 JST
```

## 8.3 cloudwatch-alarms

| 項目 | 値 |
|---|---|
| タイプ | スタンダード |
| サブスクリプション | Email（運用担当者） |
| 用途 | DLQメッセージ蓄積アラーム、異常検知失敗アラーム の通知先 |

## 8.4 batch-task-failure

| 項目 | 値 |
|---|---|
| タイプ | スタンダード |
| サブスクリプション | Lambda（`batch-restart-function`） |
| 用途 | EventBridge がバッチタスクの異常停止を検知し、Lambda を起動する |

------------------------------------------------------------------------

# 9. Amazon EventBridge

## 9.1 バッチスケジュールルール

日次レポートバッチを毎日 03:00 JST に起動する。

| 項目 | 値 |
|---|---|
| ルール名 | `daily-report-batch-schedule` |
| タイプ | スケジュール |
| cron式 | `cron(0 18 * * ? *)` （UTC 18:00 = JST 03:00） |
| ターゲット | ECS RunTask（Batch タスク定義） |
| IAMロール | `eventbridge-ecs-role`（ECS RunTask 権限） |

## 9.2 バッチタスク異常停止検知ルール

ECS Batch タスクが異常終了（exit code ≠ 0）した場合に SNS へ通知し、Lambda 経由で1回だけ再実行する。

| 項目 | 値 |
|---|---|
| ルール名 | `batch-task-stopped-rule` |
| タイプ | イベントパターン |
| ターゲット | SNS トピック `batch-task-failure` |

**イベントパターン:**
```json
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Task State Change"],
  "detail": {
    "clusterArn": ["arn:aws:ecs:ap-northeast-1:{ACCOUNT_ID}:cluster/home-smart-factory"],
    "taskDefinitionArn": [{"prefix": "arn:aws:ecs:ap-northeast-1:{ACCOUNT_ID}:task-definition/home-smart-factory-batch"}],
    "lastStatus": ["STOPPED"],
    "stopCode": ["TaskFailedToStart", "EssentialContainerExited"],
    "startedBy": [{"anything-but": "lambda-restart"}],
    "containers": {
      "exitCode": [{"anything-but": 0}]
    }
  }
}
```

> **再実行ループ防止:** Lambda が再実行するタスクには `startedBy="lambda-restart"` を付与する（下記セクション10.1参照）。このパターンは `startedBy` が `"lambda-restart"` のタスク停止を除外するため、Lambda再実行タスクが失敗しても再度Lambdaは起動されない（1回限りの再実行を保証）。
>
> **補足:** スケジュールによる正常終了（exit code = 0）はこのルールにマッチしないため、再実行Lambdaは起動されない。

------------------------------------------------------------------------

# 10. AWS Lambda

## 10.1 バッチ再実行Lambda（batch-restart-function）

ECS Batch タスクの異常終了を受けて、1回だけバッチタスクを再実行する。

| 項目 | 値 |
|---|---|
| 関数名 | `batch-restart-function` |
| ランタイム | Python 3.12 |
| メモリ | 128 MB |
| タイムアウト | 30秒 |
| トリガー | SNS トピック `batch-task-failure` |
| IAMロール | `lambda-batch-restart-role`（ECS RunTask 権限） |

**処理内容:**
1. SNSメッセージからイベント内容を取得
2. `startedBy="lambda-restart"` を付与して ECS RunTask API を呼び出す（ループ防止）
3. 再実行結果（タスクARN）を CloudWatch Logs に出力

**再実行の冪等性:**
バッチタスク内で `INSERT ... ON CONFLICT (user_id, report_date) DO NOTHING` を使用しているため、処理済みユーザーのレポートは重複生成されない。

**コード概要:**
```python
import boto3, json, os

ecs = boto3.client('ecs')

def handler(event, context):
    print(f"Received event: {json.dumps(event)}")
    
    response = ecs.run_task(
        cluster=os.environ['ECS_CLUSTER'],
        taskDefinition=os.environ['BATCH_TASK_DEFINITION'],
        launchType='FARGATE',
        startedBy='lambda-restart',  # ループ防止: EventBridgeルールの除外条件と対応
        networkConfiguration={
            'awsvpcConfiguration': {
                'subnets': [os.environ['SUBNET_ID']],
                'securityGroups': [os.environ['SECURITY_GROUP_ID']],
                'assignPublicIp': 'DISABLED'
            }
        }
    )
    
    task_arn = response['tasks'][0]['taskArn']
    print(f"Batch task restarted: {task_arn}")
    return {'taskArn': task_arn}
```

**環境変数:**

| 変数名 | 値 |
|---|---|
| ECS_CLUSTER | `home-smart-factory` |
| BATCH_TASK_DEFINITION | `home-smart-factory-batch` |
| SUBNET_ID | プライベートサブネットID |
| SECURITY_GROUP_ID | sg-ecs-batch のID |

------------------------------------------------------------------------

# 11. Amazon CloudWatch

## 11.1 ロググループ

| ロググループ | 保持期間 | 対象 |
|---|---|---|
| `/ecs/home-smart-factory/worker` | 365日 | ECS Worker ログ |
| `/ecs/home-smart-factory/batch` | 365日 | ECS Batch ログ |
| `/ecs/home-smart-factory/backend` | 365日 | ECS Backend ログ |
| `/aws/lambda/batch-restart-function` | 365日 | Lambda ログ |
| `/aws/iotcore/rule-errors` | 365日 | IoT Rule エラーアクションログ |

## 11.2 メトリクスフィルター

### 11.2.1 異常検知失敗フィルター

anomaly_logs への INSERT 失敗を検知する。

| 項目 | 値 |
|---|---|
| フィルター名 | `anomaly-insert-failure` |
| ロググループ | `/ecs/home-smart-factory/worker` |
| フィルターパターン | `"ERROR" "anomaly_logs INSERT failed"` |
| メトリクス名前空間 | `HomeSmartFactory/Worker` |
| メトリクス名 | `AnomalyInsertFailureCount` |
| メトリクス値 | 1 |
| デフォルト値 | 0 |

### 11.2.2 DLQメッセージ蓄積検知フィルター

DLQへのメッセージ移動は SQS の標準メトリクス `NumberOfMessagesSent` で監視するため、Logsフィルターは不要。

## 11.3 CloudWatch アラーム

### 11.3.1 異常検知失敗アラーム

| 項目 | 値 |
|---|---|
| アラーム名 | `anomaly-insert-failure-alarm` |
| メトリクス | `HomeSmartFactory/Worker / AnomalyInsertFailureCount` |
| 評価期間 | 5分 |
| データポイント | 1/1（1回でも発生したら発火） |
| 閾値 | ≥ 1 |
| アクション | SNS トピック `cloudwatch-alarms` へ通知 |
| 通知内容 | 「異常検知ログ（anomaly_logs）の書き込みに失敗しました。CloudWatch Logs Insights で確認してください。」 |

### 11.3.2 DLQ蓄積アラーム

| 項目 | 値 |
|---|---|
| アラーム名 | `iot-data-dlq-messages-alarm` |
| メトリクス | `AWS/SQS / NumberOfMessagesSent`（キュー: `iot-data-dlq`） |
| 評価期間 | 5分 |
| データポイント | 1/1 |
| 閾値 | ≥ 1 |
| アクション | SNS トピック `cloudwatch-alarms` へ通知 |
| 通知内容 | 「DLQ（iot-data-dlq）にメッセージが蓄積されています。手動調査・リドライブが必要です。」 |

### 11.3.3 バッチ失敗アラーム

ECS タスク異常停止は EventBridge ルールで検知するため、CloudWatch Alarm は不要。Lambda の実行結果は `/aws/lambda/batch-restart-function` のログで確認する。

### 11.3.4 RDS CPU使用率アラーム

| 項目 | 値 |
|---|---|
| アラーム名 | `rds-cpu-high` |
| メトリクス | `AWS/RDS / CPUUtilization` |
| 評価期間 | 5分 |
| データポイント | 1/1 |
| 閾値 | ≥ 80% |
| アクション | SNS トピック `cloudwatch-alarms` へ通知 |

### 11.3.5 RDS ストレージ残量アラーム

| 項目 | 値 |
|---|---|
| アラーム名 | `rds-storage-low` |
| メトリクス | `AWS/RDS / FreeStorageSpace` |
| 評価期間 | 5分 |
| データポイント | 1/1 |
| 閾値 | ≤ 5,368,709,120 bytes（5 GB） |
| アクション | SNS トピック `cloudwatch-alarms` へ通知 |

### 11.3.6 RDS 接続数アラーム

| 項目 | 値 |
|---|---|
| アラーム名 | `rds-connections-high` |
| メトリクス | `AWS/RDS / DatabaseConnections` |
| 評価期間 | 5分 |
| データポイント | 1/1 |
| 閾値 | ≥ 80（max_connections=100 の 80%） |
| アクション | SNS トピック `cloudwatch-alarms` へ通知 |

### 11.3.7 ECS Worker タスク数アラーム

| 項目 | 値 |
|---|---|
| アラーム名 | `ecs-worker-task-count-low` |
| メトリクス | `AWS/ECS / RunningTaskCount`（サービス: `worker`） |
| 評価期間 | 5分 |
| データポイント | 1/1 |
| 閾値 | < 1 |
| アクション | SNS トピック `cloudwatch-alarms` へ通知 |

### 11.3.8 IoT Rule エラーアラーム

| 項目 | 値 |
|---|---|
| アラーム名 | `iot-rule-error-alarm` |
| メトリクス | `AWS/IoT / Failure`（ルール: `iot_to_sqs_rule`） |
| 評価期間 | 5分 |
| データポイント | 1/1 |
| 閾値 | ≥ 1 |
| アクション | SNS トピック `cloudwatch-alarms` へ通知 |

## 11.4 CloudWatch Logs Insights クエリ集

**異常検知失敗の調査:**
```
fields @timestamp, @message
| filter @message like /ERROR/
| filter @message like /anomaly_logs INSERT failed/
| sort @timestamp desc
| limit 50
```

**バッチ処理の失敗ユーザー特定:**
```
fields @timestamp, @message
| filter @message like /ERROR/
| filter @logStream like /batch/
| sort @timestamp desc
| limit 100
```

------------------------------------------------------------------------

# 12. IAMロール・ポリシー

## 12.1 ECS Worker タスクロール（ecs-worker-task-role）

| 許可アクション | リソース |
|---|---|
| `sqs:ReceiveMessage` | `iot-data-queue` |
| `sqs:DeleteMessage` | `iot-data-queue` |
| `sqs:GetQueueAttributes` | `iot-data-queue` |
| `sns:Publish` | `iot-anomaly-notification` |
| `logs:CreateLogStream`, `logs:PutLogEvents` | `/ecs/home-smart-factory/worker` |

## 12.2 ECS Batch タスクロール（ecs-batch-task-role）

| 許可アクション | リソース |
|---|---|
| `logs:CreateLogStream`, `logs:PutLogEvents` | `/ecs/home-smart-factory/batch` |

> **NOTE:** Batch は RDS にのみアクセスする。RDS へのアクセスはセキュリティグループで制御するため、IAM権限は Logs のみ。

## 12.3 ECS Backend タスクロール（ecs-backend-task-role）

| 許可アクション | リソース |
|---|---|
| `logs:CreateLogStream`, `logs:PutLogEvents` | `/ecs/home-smart-factory/backend` |

> **NOTE:** Backend は RDS と Redis にアクセスする。どちらもセキュリティグループで制御するため、IAM権限は Logs のみ。

## 12.4 Lambda 実行ロール（lambda-batch-restart-role）

| 許可アクション | リソース |
|---|---|
| `ecs:RunTask` | `home-smart-factory-batch` タスク定義 |
| `iam:PassRole` | `ecs-batch-task-role` |
| `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` | `/aws/lambda/batch-restart-function` |

## 12.5 EventBridge 実行ロール（eventbridge-ecs-role）

| 許可アクション | リソース |
|---|---|
| `ecs:RunTask` | `home-smart-factory-batch` タスク定義 |
| `iam:PassRole` | `ecs-batch-task-role` |

------------------------------------------------------------------------

# 13. Amazon ECR

## 13.1 リポジトリ一覧

| リポジトリ名 | 用途 |
|---|---|
| `home-smart-factory/worker` | ECS Worker |
| `home-smart-factory/batch` | ECS Batch |
| `home-smart-factory/backend` | ECS Backend |
| `home-smart-factory/grafana` | Grafana（公式イメージのミラー） |

## 13.2 イメージタグ戦略

**タグ形式:** `{git-sha-7桁}` をプライマリタグとし、最新ビルドに `latest` タグを併せて付与する。

```
例: home-smart-factory/backend:a1b2c3d
    home-smart-factory/backend:latest
```

| タグ | 付与タイミング | 用途 |
|---|---|---|
| `{git-sha-7桁}` | 全ビルド | 特定バージョンへのロールバック用 |
| `latest` | 全ビルド | ECS タスク定義が常に最新イメージを参照する際のエイリアス |

**ECS タスク定義のイメージ参照:** デプロイ時に `{git-sha}` タグを指定したタスク定義のリビジョンを作成する。`latest` タグのままデプロイしない（意図しないイメージ差し替えを防ぐため）。

## 13.3 ライフサイクルポリシー

不要なイメージが蓄積しないよう、全リポジトリに以下のライフサイクルポリシーを設定する。

| ルール | 条件 | アクション |
|---|---|---|
| 1 | タグなしイメージが1日以上経過 | 削除 |
| 2 | `latest` 以外のタグ付きイメージが10件を超えた場合、古い順に超過分 | 削除 |

## 13.4 イメージスキャン

| 項目 | 値 |
|---|---|
| スキャンタイミング | プッシュ時に自動スキャン（Scan on push） |
| 対象 | 全リポジトリ |
| 脆弱性検知時の対応 | CRITICAL / HIGH 検知時はデプロイを手動で判断する（自動ブロックはしない） |

------------------------------------------------------------------------

# 14. Application Load Balancer（ALB）

| 項目 | 値 |
|---|---|
| 名前 | `home-smart-factory-alb` |
| タイプ | Application Load Balancer |
| スキーム | internet-facing |
| リスナー | HTTPS:443 |
| 証明書 | ACM（AWS Certificate Manager）発行の証明書 |
| ターゲットグループ | ECS Backend（ポート 8080） |
| HTTPSリダイレクト | HTTP:80 → HTTPS:443 |

**ヘルスチェック設定:**

| 項目 | 値 |
|---|---|
| パス | `GET /health` |
| 間隔 | 30秒 |
| タイムアウト | 10秒 |
| 正常閾値 | 2回連続成功 |
| 異常閾値 | 3回連続失敗 |
| 成功HTTPコード | 200 |

------------------------------------------------------------------------

# 15. Raspberry Pi（デバイス層）設定

## 14.1 Java Collector 設定

| 項目 | 値 |
|---|---|
| 接続先 | AWS IoT Core（MQTT over TLS、ポート 8883） |
| 送信間隔 | 1分（60秒） |
| QoS | 1 |
| 証明書格納場所 | `/etc/iot-collector/certs/` |

## 14.2 証明書ファイル

| ファイル | 用途 |
|---|---|
| `device-cert.pem` | デバイス証明書（IoT Core で発行） |
| `private-key.pem` | 秘密鍵 |
| `AmazonRootCA1.pem` | AWS ルートCA証明書 |

## 14.3 MQTTペイロード形式

```json
{
  "device_id": "room01",
  "temperature": 25.3,
  "humidity": 60.1,
  "motion": 1,
  "power_w": 120.5,
  "recorded_at": "2026-01-15T10:00:00+09:00"
}
```

| フィールド | 型 | 説明 |
|---|---|---|
| device_id | string | デバイス識別子（devices テーブルの device_id と一致） |
| temperature | number \| null | 温度（℃）。センサー未搭載時は null |
| humidity | number \| null | 湿度（%）。センサー未搭載時は null |
| motion | 0 \| 1 \| null | 人感センサー。センサー未搭載時は null |
| power_w | number \| null | 消費電力（W）。センサー未搭載時は null |
| recorded_at | ISO 8601 | データ取得時刻（タイムゾーン付き） |

## 14.4 MQTT接続失敗時の挙動

| ケース | 挙動 |
|---|---|
| 認証エラー（CONNACK returnCode=5） | エラーログ出力してプロセス停止。証明書の確認が必要 |
| ネットワーク断（タイムアウト） | 指数バックオフでリトライ（1秒 → 2秒 → 4秒 → 最大60秒） |

------------------------------------------------------------------------

# 16. 障害対応フロー一覧

## 15.1 障害パターンと対応

| 障害 | 検知手段 | 対応 |
|---|---|---|
| SQS DLQ にメッセージ蓄積 | CloudWatch Alarm（`iot-data-dlq-messages-alarm`）→ メール通知 | DLQメッセージ内容を確認し、原因解消後に手動リドライブ |
| 異常検知ログ書き込み失敗 | CloudWatch Alarm（`anomaly-insert-failure-alarm`）→ メール通知 | CloudWatch Logs Insights で該当レコードを特定し、RDS障害状況を確認 |
| バッチタスク異常終了 | EventBridge ルール → SNS → Lambda が自動1回再実行 | Lambda ログで再実行結果を確認。再実行後も失敗する場合は手動対応 |
| RDS CPU/ストレージ/接続数異常 | CloudWatch Alarm（`rds-cpu-high` / `rds-storage-low` / `rds-connections-high`）→ メール通知 | RDS コンソールで状況確認。フェイルオーバーはマルチAZにより自動（30〜60秒）。復旧後にDLQリドライブ実施 |
| ECS Worker タスク数 0 | CloudWatch Alarm（`ecs-worker-task-count-low`）→ メール通知 | ECS コンソールでタスク状況・イベントログを確認。ECS が自動で再起動を試みる |
