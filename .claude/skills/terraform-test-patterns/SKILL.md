---
name: terraform-test-patterns
description: このプロジェクト固有の Terraform テスト実装パターン。mock_provider の使い分け、variables ブロック、plan 時点でアサート可能な値の判断基準、run ブロックの命名規則を網羅する。tftest.hcl を新規作成するとき、既存テストを修正するときに必ず参照する。
---

# Terraform テストパターン（このプロジェクト専用）

## 絶対に使わないもの

| 禁止 | 理由 |
|------|------|
| `command = apply` | テスト環境から AWS へ実リソースを作成しない |
| `mock_resource` | リソースのモックは不要。plan 時点の値のみ検証する |

全テストは `command = plan` のみで完結させる。

---

## ファイル先頭の固定ブロック

### mock_provider が必要なモジュール

モジュール内で `data "aws_caller_identity"` または `data "aws_iam_policy_document"` を使っている場合は、ファイル先頭に以下を置く。

```hcl
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AKIAIOSFODNN7EXAMPLE"
    }
  }

  # aws_iam_policy_document はデフォルトで空文字列を返すため、有効な JSON を返すよう設定する
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}
```

### mock_provider が不要なモジュール

`data` ソースを使っていないモジュール（例: `vpc`）は `mock_provider` ブロック不要。

---

## variables ブロック（全ファイル共通）

全ての `.tftest.hcl` に以下の `variables` ブロックを置く。

```hcl
variables {
  admin_cidr_blocks = ["192.0.2.0/32"]
  # テスト用ダミー認証情報（機密情報ではない）
  db_username    = "testadmin"
  db_password    = "testpassword123"
  operator_email = "test@example.com"
  domain_name    = "api.example.com"
}
```

---

## run ブロックの構造

```hcl
run "<検証内容を表すスネークケース>" {
  command = plan

  # <なぜこの値が plan 時点で確定するかの理由>
  assert {
    condition     = <条件式>
    error_message = "<日本語のエラーメッセージ>"
  }
}
```

**命名規則**: `<モジュール>_<検証内容>` の形にする。

```hcl
# 良い例
run "ecs_cluster_name" { ... }
run "iam_role_names_contain_name_prefix" { ... }
run "public_subnets_have_two_azs" { ... }

# 悪い例
run "test1" { ... }
run "check_ecs" { ... }
```

---

## plan 時点でアサートできる値・できない値

### アサートできる（name_prefix などの入力値から確定する）

```hcl
# 出力値の一致
condition = module.ecs.cluster_name == "home-smart-factory"

# 出力値のカウント
condition = length(module.iam.role_names) == 7

# マップのキー存在確認
condition = contains(keys(module.vpc.public_subnet_ids), "1a")

# 文字列のプレフィックス確認
condition = startswith(module.rds.instance_id, "home-smart-factory")
```

### アサートできない（apply 後に AWS が返す値）

```hcl
# ❌ ARN（apply 後に確定）
condition = module.rds.db_arn == "arn:aws:rds:..."

# ❌ ID（apply 後に AWS が採番）
condition = module.vpc.vpc_id == "vpc-xxxxxxxx"

# ❌ DNS名（apply 後に確定）
condition = module.alb.dns_name == "..."
```

---

## モジュール別・mock_provider 要否一覧

| モジュール | mock_provider | 理由 |
|---|---|---|
| `vpc` | 不要 | data ソースなし |
| `iam` | **必要** | `aws_caller_identity`, `aws_iam_policy_document` |
| `ecr` | 不要 | data ソースなし |
| `rds` | 不要 | data ソースなし |
| `elasticache` | 不要 | data ソースなし |
| `sqs` | 不要 | data ソースなし |
| `sns` | 不要 | data ソースなし |
| `iot` | 不要 | data ソースなし |
| `alb` | 不要 | data ソースなし |
| `ecs` | **必要** | `aws_caller_identity`, `aws_iam_policy_document` |
| `lambda` | **必要** | `aws_caller_identity`, `aws_iam_policy_document` |
| `eventbridge` | **必要** | `aws_caller_identity`, `aws_iam_policy_document` |
| `cloudwatch` | 不要 | data ソースなし |

> 新しいモジュールを追加した場合は、`data` ソースの有無を確認してこの表を更新する。

---

## テンプレート（mock_provider あり）

```hcl
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AKIAIOSFODNN7EXAMPLE"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  admin_cidr_blocks = ["192.0.2.0/32"]
  db_username       = "testadmin"
  db_password       = "testpassword123"
  operator_email    = "test@example.com"
  domain_name       = "api.example.com"
}

run "<検証内容>" {
  command = plan

  assert {
    condition     = <条件式>
    error_message = "<日本語のエラーメッセージ>"
  }
}
```

## テンプレート（mock_provider なし）

```hcl
variables {
  admin_cidr_blocks = ["192.0.2.0/32"]
  db_username       = "testadmin"
  db_password       = "testpassword123"
  operator_email    = "test@example.com"
  domain_name       = "api.example.com"
}

run "<検証内容>" {
  command = plan

  assert {
    condition     = <条件式>
    error_message = "<日本語のエラーメッセージ>"
  }
}
```
