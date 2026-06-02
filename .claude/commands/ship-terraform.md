---
description: Terraform 実装の検証・テスト・振り返り・PR 作成を行う
---

# /ship-terraform <機能名>

**引数:** 機能名 (例: `/ship-terraform CloudWatchアラーム`)

---

## ステップ0: 前提確認

`.steering/` 配下から引数の機能名に対応する `tasklist.md` を読み込む。
未完了タスク（`[ ]`）が残っている場合は `/implement-terraform <機能名>` を先に完了させるよう案内して終了する。

---

## ステップ1: 自己レビュー

実装したファイルを読み込み、以下の観点で確認する。問題があれば修正してから次に進む。

- **命名規則**: スネークケース、リソースタイプをリソース名に繰り返していないか
- **変数**: `description` / `type` / `sensitive` が適切に設定されているか
- **セキュリティ**: IAM ポリシーに `*` が使われていないか、SG が最小開放か
- **locals**: 共通タグ・名前プレフィックスが集約されているか
- **lifecycle**: RDS 等の重要リソースに `prevent_destroy = true` が設定されているか

---

## ステップ2: 自動テスト

以下を順番に実行し、全てパスすることを確認する。失敗した場合は原因を分析・修正してから再実行する。

```bash
cd terraform/envs/prod && terraform fmt -check -recursive
cd terraform/envs/prod && terraform validate
cd terraform/envs/prod && terraform test
cd terraform/envs/prod && terraform plan
```

`terraform fmt` のエラーは `terraform fmt -recursive` で自動修正してから再実行する。

---

## ステップ3: 振り返り

`tasklist.md` の末尾「実装後の振り返り」セクションに以下を記入する。

```markdown
## 実装後の振り返り

**実装完了日**: YYYY-MM-DD

### 計画と実績の差分

| 項目 | 計画 | 実績 |
|------|------|------|

### 設計判断の記録

> 複数の選択肢があった場合や、仕様書に書かれていない理由で実装方針を決めた場合に記録する。

- **[判断した内容]**: [選んだ理由・却下した選択肢]

### 発生した問題と対処

- **[問題の内容]**: [原因と解決策]

### 次回への改善提案
```

---

## ステップ4: ドキュメント更新

今回の変更がインフラ構成に影響を与える場合（新規リソース追加・構成変更など）、`docs/basic-design/infrastructure-design.md` の該当セクションを `Edit` ツールで更新する。

---

## ステップ5: PR 作成

feature ブランチから main への PR を作成する。

- タイトル: `feat(<機能名>): <実装内容の概要>`
- ボディ: 実装したリソース・変更ファイル・テスト確認済みの旨を記載する
