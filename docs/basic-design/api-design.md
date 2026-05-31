# API設計書

## Home Smart Factory -- IoT設備監視基盤

------------------------------------------------------------------------

# 1. 概要

| 項目 | 内容 |
|---|---|
| アーキテクチャ | RESTful API |
| データ形式 | JSON（Content-Type: application/json） |
| 認証方式 | Redisセッション（Cookie: `session_id`） |
| ベースURL | `https://api.example.com` |
| タイムゾーン | レスポンスはUTC、クライアント側でJST変換 |

------------------------------------------------------------------------

# 2. 認証

Google OAuthによるログインを起点にRedisセッションを発行する。
`/auth/**` 以外の全エンドポイントはセッションCookieが必須。
セッションが無効な場合は `401 Unauthorized` を返す。

------------------------------------------------------------------------

# 3. 共通レスポンス形式

## 3.1 成功

```json
{
  "data": { ... }
}
```

リスト系は以下。

```json
{
  "data": [ ... ],
  "pagination": {
    "total": 100,
    "page": 1,
    "per_page": 20
  }
}
```

## 3.2 エラー

```json
{
  "error": {
    "code": "DEVICE_NOT_FOUND",
    "message": "指定されたデバイスが見つかりません"
  }
}
```

## 3.3 共通HTTPステータスコード

| コード | 用途 |
|---|---|
| 200 | 成功 |
| 201 | リソース作成成功 |
| 204 | 成功（レスポンスボディなし） |
| 400 | リクエスト不正（バリデーションエラー） |
| 401 | 未認証（セッション無効） |
| 403 | 権限なし（他ユーザーのリソースへのアクセス） |
| 404 | リソースが存在しない |
| 409 | 競合（重複登録など） |
| 429 | レート制限超過 |
| 500 | サーバー内部エラー |

------------------------------------------------------------------------

# 4. エンドポイント一覧

## 4.1 認証（Auth）

### `GET /auth/google`

Google OAuth認証ページへリダイレクト。

**レスポンス**
- `302 Found` → Google認証ページへリダイレクト

---

### `GET /auth/google/callback`

Google OAuth認証後のコールバック。セッションを発行し、フロントエンドへリダイレクト。
初回ログイン時はusersテーブルに自動登録する。

**クエリパラメータ**

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| code | string | YES | Googleが発行する認証コード |
| state | string | YES | CSRF対策トークン |

**レスポンス**
- `302 Found` → フロントエンドトップページへリダイレクト
- セッションCookie（`session_id`）をセット

---

### `POST /auth/logout`

セッションを破棄しログアウト。

**レスポンス**
- `204 No Content`

------------------------------------------------------------------------

## 4.2 ユーザー（Users）

### `GET /api/users/me`

ログイン中のユーザー情報を取得。

**レスポンス `200`**

```json
{
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "email": "user@example.com",
    "created_at": "2026-01-01T00:00:00Z"
  }
}
```

---

### `DELETE /api/users/me`

ユーザーアカウントを退会・削除する。関連する全データを同一トランザクション内で削除。

**レスポンス**
- `204 No Content`

------------------------------------------------------------------------

## 4.3 デバイス（Devices）

### `GET /api/devices`

ログインユーザーが保有するデバイス一覧を取得。

**レスポンス `200`**

```json
{
  "data": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "device_id": "room01",
      "name": "リビング",
      "created_at": "2026-01-01T00:00:00Z"
    }
  ]
}
```

---

### `POST /api/devices`

新しいデバイスを登録する。

**リクエストボディ**

```json
{
  "device_id": "room01",
  "name": "リビング"
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| device_id | string | YES | デバイス識別子（英数字・ハイフン、最大100文字） |
| name | string | NO | 表示名（最大255文字） |

**レスポンス `201`**

```json
{
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "device_id": "room01",
    "name": "リビング",
    "created_at": "2026-01-15T10:00:00Z"
  }
}
```

**エラー**
- `409 Conflict` → `device_id` が既に登録済み

---

### `PATCH /api/devices/{id}`

デバイスの表示名を更新する。

**パスパラメータ**

| パラメータ | 型 | 説明 |
|---|---|---|
| id | uuid | デバイスID（devices.id） |

**リクエストボディ**

```json
{
  "name": "寝室"
}
```

**レスポンス `200`**

```json
{
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "device_id": "room01",
    "name": "寝室",
    "created_at": "2026-01-15T10:00:00Z"
  }
}
```

---

### `DELETE /api/devices/{id}`

デバイスを削除する。関連する `iot_data`・`anomaly_logs` を同一トランザクション内で削除。

**レスポンス**
- `204 No Content`

**エラー**
- `404 Not Found` → デバイスが存在しない、または他ユーザーのデバイス

------------------------------------------------------------------------

## 4.4 IoTデータ（IoT Data）

### `GET /api/iot-data`

センサーデータを取得。ダッシュボード表示・グラフ描画に使用。

**クエリパラメータ**

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| device_id | string | NO | デバイス識別子でフィルタ（未指定時は全デバイス） |
| from | datetime | YES | 取得開始日時（ISO 8601） |
| to | datetime | YES | 取得終了日時（ISO 8601） |
| page | int | NO | ページ番号（デフォルト: 1） |
| per_page | int | NO | 1ページあたり件数（デフォルト: 100、最大: 1000） |

**レスポンス `200`**

```json
{
  "data": [
    {
      "id": 1,
      "device_id": "room01",
      "temperature": 25.3,
      "humidity": 60.1,
      "motion": 1,
      "power_w": 120.5,
      "recorded_at": "2026-01-15T10:00:00Z"
    }
  ],
  "pagination": {
    "total": 1440,
    "page": 1,
    "per_page": 100
  }
}
```

------------------------------------------------------------------------

## 4.5 異常検知閾値（Anomaly Thresholds）

### `GET /api/anomaly-thresholds`

ログインユーザーの閾値設定一覧を取得。

**レスポンス `200`**

```json
{
  "data": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "metric_type": "temperature",
      "min_value": 10.0,
      "max_value": 35.0,
      "enabled": true,
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-01-01T00:00:00Z"
    }
  ]
}
```

---

### `POST /api/anomaly-thresholds`

閾値設定を新規作成する。

**リクエストボディ**

```json
{
  "metric_type": "temperature",
  "min_value": 10.0,
  "max_value": 35.0
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| metric_type | string | YES | `temperature` / `humidity` / `power_w` |
| min_value | number | NO | 下限閾値（`power_w` には不要） |
| max_value | number | NO | 上限閾値 |

**バリデーション**
- `metric_type` が `power_w` の場合、`min_value` は無効（無視）
- `min_value` と `max_value` を両方省略することは不可
- 同一 `metric_type` の設定は1ユーザーにつき1件まで

**レスポンス `201`**

```json
{
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "metric_type": "temperature",
    "min_value": 10.0,
    "max_value": 35.0,
    "enabled": true,
    "created_at": "2026-01-15T10:00:00Z",
    "updated_at": "2026-01-15T10:00:00Z"
  }
}
```

**エラー**
- `409 Conflict` → 同一 `metric_type` の設定が既に存在

---

### `PATCH /api/anomaly-thresholds/{id}`

閾値設定を更新する。

**パスパラメータ**

| パラメータ | 型 | 説明 |
|---|---|---|
| id | uuid | 閾値設定ID |

**リクエストボディ**（変更するフィールドのみ指定可）

```json
{
  "max_value": 40.0,
  "enabled": false
}
```

**レスポンス `200`** → 更新後のリソースを返す（`POST` と同形式）

---

### `DELETE /api/anomaly-thresholds/{id}`

閾値設定を削除する。

**レスポンス**
- `204 No Content`

------------------------------------------------------------------------

## 4.6 異常検知ログ（Anomaly Logs）

### `GET /api/anomaly-logs`

異常検知ログ一覧を取得。新しい順で返す。

**クエリパラメータ**

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| device_id | string | NO | デバイス識別子でフィルタ |
| metric_type | string | NO | 検知対象でフィルタ |
| from | datetime | NO | 取得開始日時 |
| to | datetime | NO | 取得終了日時 |
| page | int | NO | ページ番号（デフォルト: 1） |
| per_page | int | NO | 件数（デフォルト: 20、最大: 100） |

**レスポンス `200`**

```json
{
  "data": [
    {
      "id": 1,
      "device_id": "room01",
      "metric_type": "temperature",
      "threshold_value": 35.0,
      "actual_value": 38.2,
      "message": "温度が上限閾値(35.0℃)を超えました: 38.2℃",
      "detected_at": "2026-01-15T10:00:00Z"
    }
  ],
  "pagination": {
    "total": 50,
    "page": 1,
    "per_page": 20
  }
}
```

------------------------------------------------------------------------

## 4.7 日次レポート（Daily Reports）

### `GET /api/reports`

日次レポート一覧を取得。新しい順で返す。

**クエリパラメータ**

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| page | int | NO | ページ番号（デフォルト: 1） |
| per_page | int | NO | 件数（デフォルト: 20、最大: 100） |

**レスポンス `200`**

```json
{
  "data": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "report_date": "2026-01-14",
      "total_power_kwh": 3.52,
      "avg_temperature": 22.1,
      "avg_humidity": 58.3,
      "total_motion_minutes": 420,
      "anomaly_count": 2,
      "created_at": "2026-01-15T03:00:00Z"
    }
  ],
  "pagination": {
    "total": 30,
    "page": 1,
    "per_page": 20
  }
}
```

---

### `GET /api/reports/{id}`

レポート詳細を取得。異常サマリー含む。

**レスポンス `200`**

```json
{
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "report_date": "2026-01-14",
    "total_power_kwh": 3.52,
    "avg_temperature": 22.1,
    "avg_humidity": 58.3,
    "total_motion_minutes": 420,
    "anomaly_count": 2,
    "anomaly_summary": [
      {
        "device_id": "room01",
        "metric_type": "temperature",
        "count": 2,
        "max_value": 38.2
      }
    ],
    "download_count_today": 1,
    "created_at": "2026-01-15T03:00:00Z"
  }
}
```

**補足**
- `download_count_today`: 当日のダウンロード済み回数（フロント側でボタン制御に使用）

---

### `POST /api/reports/{id}/download`

レポートをPDF形式でダウンロードする。1日3回まで。

**レスポンス `200`**
- `Content-Type: application/pdf`
- `Content-Disposition: attachment; filename="report_2026-01-14.pdf"`
- バイナリ（PDFファイル）

**エラー**
- `429 Too Many Requests` → 当日のダウンロード回数が3回に達している

------------------------------------------------------------------------

# 5. エラーコード一覧

| コード | HTTPステータス | 説明 |
|---|---|---|
| UNAUTHORIZED | 401 | セッションが無効 |
| FORBIDDEN | 403 | 他ユーザーのリソースへのアクセス |
| DEVICE_NOT_FOUND | 404 | デバイスが存在しない |
| REPORT_NOT_FOUND | 404 | レポートが存在しない |
| THRESHOLD_NOT_FOUND | 404 | 閾値設定が存在しない |
| DEVICE_ALREADY_EXISTS | 409 | device_idが既に登録済み |
| THRESHOLD_ALREADY_EXISTS | 409 | 同一metric_typeの設定が既に存在 |
| DOWNLOAD_LIMIT_EXCEEDED | 429 | ダウンロード回数上限（3回/日）に達した |
| INTERNAL_SERVER_ERROR | 500 | サーバー内部エラー |
