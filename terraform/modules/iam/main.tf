data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.aws_region
  np         = var.name_prefix

  # ARN 構築（依存リソースが未作成でも参照できるよう名前規則から導出）
  sqs_queue_arn      = "arn:aws:sqs:${local.region}:${local.account_id}:${local.np}-iot-data-queue"
  sns_anomaly_arn    = "arn:aws:sns:${local.region}:${local.account_id}:${local.np}-iot-anomaly-notification"
  # :* でリビジョン問わず全バージョンを許可する（デプロイごとにリビジョンが増えるため）
  batch_task_def_arn = "arn:aws:ecs:${local.region}:${local.account_id}:task-definition/${local.np}-batch:*"

  # CloudWatch Logs ARN プレフィックス
  cw_logs_base = "arn:aws:logs:${local.region}:${local.account_id}:log-group"

  # Secrets Manager ARN プレフィックス（Grafana 用）
  grafana_secret_arn_prefix = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${local.np}/grafana*"
}

# ---------------------------------------------------------------
# ECS タスク実行ロール（全 ECS タスク共通）
# ---------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.np}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${local.np}-ecs-task-execution"
  }
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Grafana はコンテナ起動時に Secrets Manager からパスワードを取得する
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.grafana_secret_arn_prefix]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${local.np}-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ---------------------------------------------------------------
# ECS Worker タスクロール
# ---------------------------------------------------------------

resource "aws_iam_role" "ecs_worker" {
  name               = "${local.np}-ecs-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${local.np}-ecs-worker-task"
  }
}

data "aws_iam_policy_document" "ecs_worker" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [local.sqs_queue_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [local.sns_anomaly_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.cw_logs_base}:/ecs/${local.np}/worker:*"]
  }
}

resource "aws_iam_role_policy" "ecs_worker" {
  name   = "${local.np}-ecs-worker"
  role   = aws_iam_role.ecs_worker.id
  policy = data.aws_iam_policy_document.ecs_worker.json
}

# ---------------------------------------------------------------
# ECS Batch タスクロール
# ---------------------------------------------------------------

resource "aws_iam_role" "ecs_batch" {
  name               = "${local.np}-ecs-batch-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${local.np}-ecs-batch-task"
  }
}

data "aws_iam_policy_document" "ecs_batch" {
  # Batch は RDS にのみアクセス（SG 制御）。Logs のみ IAM 権限が必要。
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.cw_logs_base}:/ecs/${local.np}/batch:*"]
  }
}

resource "aws_iam_role_policy" "ecs_batch" {
  name   = "${local.np}-ecs-batch"
  role   = aws_iam_role.ecs_batch.id
  policy = data.aws_iam_policy_document.ecs_batch.json
}

# ---------------------------------------------------------------
# ECS Backend タスクロール
# ---------------------------------------------------------------

resource "aws_iam_role" "ecs_backend" {
  name               = "${local.np}-ecs-backend-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${local.np}-ecs-backend-task"
  }
}

data "aws_iam_policy_document" "ecs_backend" {
  # Backend は RDS・Redis にアクセス（SG 制御）。Logs のみ IAM 権限が必要。
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.cw_logs_base}:/ecs/${local.np}/backend:*"]
  }
}

resource "aws_iam_role_policy" "ecs_backend" {
  name   = "${local.np}-ecs-backend"
  role   = aws_iam_role.ecs_backend.id
  policy = data.aws_iam_policy_document.ecs_backend.json
}

# ---------------------------------------------------------------
# ECS Grafana タスクロール
# ---------------------------------------------------------------

resource "aws_iam_role" "ecs_grafana" {
  name               = "${local.np}-ecs-grafana-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${local.np}-ecs-grafana-task"
  }
}

data "aws_iam_policy_document" "ecs_grafana" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.grafana_secret_arn_prefix]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.cw_logs_base}:/ecs/${local.np}/grafana:*"]
  }
}

resource "aws_iam_role_policy" "ecs_grafana" {
  name   = "${local.np}-ecs-grafana"
  role   = aws_iam_role.ecs_grafana.id
  policy = data.aws_iam_policy_document.ecs_grafana.json
}

# ---------------------------------------------------------------
# Lambda バッチ再実行ロール
# ---------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_batch_restart" {
  name               = "${local.np}-lambda-batch-restart"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Name = "${local.np}-lambda-batch-restart"
  }
}

data "aws_iam_policy_document" "lambda_batch_restart" {
  statement {
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [local.batch_task_def_arn]
  }

  # ecs:RunTask 時に ECS がタスクロールと実行ロールを引き受けるために必要
  statement {
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_batch.arn,
      aws_iam_role.execution.arn,
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.cw_logs_base}:/aws/lambda/${local.np}-batch-restart-function:*"]
  }
}

resource "aws_iam_role_policy" "lambda_batch_restart" {
  name   = "${local.np}-lambda-batch-restart"
  role   = aws_iam_role.lambda_batch_restart.id
  policy = data.aws_iam_policy_document.lambda_batch_restart.json
}

# ---------------------------------------------------------------
# EventBridge ECS 実行ロール
# ---------------------------------------------------------------

data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_ecs" {
  name               = "${local.np}-eventbridge-ecs"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json

  tags = {
    Name = "${local.np}-eventbridge-ecs"
  }
}

data "aws_iam_policy_document" "eventbridge_ecs" {
  statement {
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [local.batch_task_def_arn]
  }

  # ecs:RunTask 時に ECS がタスクロールと実行ロールを引き受けるために必要
  statement {
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_batch.arn,
      aws_iam_role.execution.arn,
    ]
  }
}

resource "aws_iam_role_policy" "eventbridge_ecs" {
  name   = "${local.np}-eventbridge-ecs"
  role   = aws_iam_role.eventbridge_ecs.id
  policy = data.aws_iam_policy_document.eventbridge_ecs.json
}
