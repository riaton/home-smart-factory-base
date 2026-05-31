# システム構成図

## Home Smart Factory -- IoT設備監視基盤

------------------------------------------------------------------------

```mermaid
flowchart TB
    subgraph Device["IoT デバイス層（ローカル）"]
        sensor["センサー群\n温湿度センサー / 人感センサー / スマートプラグ"]
        subgraph rpi["Raspberry Pi"]
            collector["Java Collector\nデータ収集クライアント（常駐）"]
        end
        sensor -->|"センサー値取得"| collector
    end

    subgraph AWS["AWS"]
        subgraph Ingestion["データ収集"]
            iotcore["AWS IoT Core\nMQTT受信"]
            sqs["Amazon SQS\n受信キュー"]
            iotcore -->|"メッセージ転送"| sqs
        end

        subgraph Compute["Amazon ECS（コンテナ）"]
            worker["データ処理ワーカー\nIoTデータ保存 / 異常検知"]
            batch["バッチワーカー\n日次レポート自動生成\n（毎日03:00 JST）"]
            backend["バックエンド\nREST API\n（認証 / デバイス管理 / レポート / 閾値設定）"]
        end

        subgraph Storage["ストレージ"]
            rds[("Amazon RDS\nPostgreSQL")]
            redis[("Amazon ElastiCache\nRedis\nセッション管理")]
        end

        sns["Amazon SNS\n異常検知メール通知"]

        sqs -->|"メッセージ取得"| worker
        worker -->|"IoTデータ保存\n異常ログ保存"| rds
        worker -->|"閾値超過時"| sns
        batch -->|"日次レポート書き込み"| rds
        backend -->|"DB読み書き"| rds
        backend -->|"セッション読み書き"| redis
    end

    subgraph Client["クライアント"]
        react["React Web アプリ\n認証 / レポート閲覧・DL\n異常ログ一覧 / 閾値設定"]
        grafana["Grafana\n設備監視ダッシュボード\nリアルタイム可視化"]
    end

    google["Google OAuth\n（外部認証）"]
    mail["メールボックス\n（通知先）"]

    collector -->|"MQTT publish"| iotcore
    react -->|"REST API"| backend
    react <-->|"OAuth2 認可フロー"| google
    backend <-->|"トークン検証"| google
    grafana -->|"直接クエリ"| rds
    sns -->|"メール送信"| mail
```

------------------------------------------------------------------------

# データフロー概要

## データ収集フロー（リアルタイム）

```
センサー群
  └─ Java Collector（センサー値取得・MQTT送信）
       └─ AWS IoT Core（MQTT受信）
            └─ Amazon SQS（キューイング）
                 └─ ECS データ処理ワーカー
                      ├─ RDS: iot_data 保存
                      ├─ RDS: 閾値チェック → anomaly_logs 保存
                      └─ SNS: 閾値超過時メール通知
```

## 日次レポート生成フロー（バッチ）

```
毎日 03:00 JST
  └─ ECS バッチワーカー
       └─ RDS: iot_data / anomaly_logs を集計
            └─ RDS: daily_reports 書き込み
```

## ユーザー操作フロー（Web）

```
ブラウザ（React）
  ├─ Google OAuth → セッション発行（Redis）
  ├─ REST API → ECS バックエンド → RDS
  │    ├─ デバイス管理（登録 / 更新 / 削除）
  │    ├─ 閾値設定（CRUD）
  │    ├─ 異常ログ一覧
  │    └─ レポート閲覧 / PDF ダウンロード
  └─ Grafana → RDS 直接クエリ（ダッシュボード表示）
```
