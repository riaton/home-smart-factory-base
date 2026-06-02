---
description: Terraform 機能の実装計画を立て、tasklist.md を生成する
---

# /plan-terraform <機能名>

**引数:** 機能名 (例: `/plan-terraform CloudWatchアラーム`)

---

## ステップ0: 再入チェック

`.steering/` 配下に引数の機能名を含むディレクトリが存在するか確認する。

- **存在する場合**: tasklist.md の現在の状態を表示して終了する。実装を再開するには `/implement-terraform <機能名>` を使うこと。
- **存在しない場合**: 以下のステップに進む。

---

## ステップ1: 準備

1. 現在の日付を `YYYYMMDD` 形式で取得する
2. `.steering/[日付]-[機能名]/` ディレクトリを作成する
3. `.steering/[日付]-[機能名]/tasklist.md` を空ファイルとして作成する

---

## ステップ2: 仕様書の読み込み

1. `CLAUDE.md` を読んでプロジェクト全体像を把握する
2. `docs/basic-design/infrastructure-design.md` を読み、実装対象リソースの要件・構成を把握する
3. 関連する設計書があれば合わせて読む（例: IoT 関連なら `docs/detailed-design/iot-message-format.md`）

---

## ステップ3: 既存パターンの調査

機能名に関連するキーワードで `terraform/` を grep し、既存の命名規則・タグ戦略・モジュール構成を把握する。

---

## ステップ4: tasklist.md の生成

以下のフォーマットを雛形として、内容を機能に合わせて置き換えて `.steering/[日付]-[機能名]/tasklist.md` を生成する。

```markdown
## フェーズ0: 仕様確認

- [ ] CLAUDE.md 読み込み
- [ ] docs/basic-design/infrastructure-design.md — [対象セクション] 確認

## フェーズ1: モジュール実装 (terraform/modules/<name>/)

- [ ] variables.tf — [変数名・型・description を列挙]
- [ ] main.tf — [作成するリソース名を列挙]
- [ ] outputs.tf — [出力値名を列挙]

## フェーズ2: ルートモジュール統合 (terraform/envs/prod/)

- [ ] main.tf — module "<name>" ブロック追加（source・変数の受け渡し）
- [ ] variables.tf — 新規変数があれば追加
- [ ] outputs.tf — 必要な出力があれば追加

## フェーズ3: テスト実装

- [ ] envs/prod/tests/<name>.tftest.hcl — plan テスト作成（[検証項目を列挙]）

## 実装後の振り返り

（/ship-terraform が記入する）
```

**タスク粒度の基準（必ず守ること）**

良い例（ファイルパス・リソース名・変数名まで書く）:

```
- [ ] modules/cloudwatch/variables.tf — alarm_name_prefix(string), thresholds(map(number))
- [ ] modules/cloudwatch/main.tf — aws_cloudwatch_metric_alarm × 3（CPU/メモリ/SQS深度）
- [ ] modules/cloudwatch/outputs.tf — alarm_arns(map(string))
- [ ] envs/prod/tests/cloudwatch.tftest.hcl — alarm_names にプレフィックスが含まれること
```

悪い例（何を作るか不明確）:

```
- [ ] CloudWatch モジュールを作る
- [ ] テストを書く
```

---

生成完了後、次のステップを案内する:

```
計画が完了しました。
実装を開始するには: /implement-terraform <機能名>
```
