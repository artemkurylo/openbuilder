# -----------------------------------------------------------------------------
# The waker
# -----------------------------------------------------------------------------
# `ob-idle-stop` on the instance owns power-off. This owns power-on: an
# EventBridge rule invokes a small Lambda every `waker_interval_minutes`, it
# evaluates the same §6 rule table against GitHub, and starts the instance only
# when something is actionable and the instance is stopped.
#
# Without it the loop only closes when the laptop CLI runs (`ob_ensure_running`),
# so a review submitted from the GitHub web UI would stall until someone opened
# a terminal. With it, the instance is off by default and the backlog itself is
# the trigger.
#
# Zero dependencies on purpose: the function is three stdlib-only Python files,
# so there is no layer to build, no container image to push, and nothing to
# rebuild when a base image moves.
# -----------------------------------------------------------------------------

data "archive_file" "waker" {
  type        = "zip"
  source_dir  = "${path.module}/../waker"
  output_path = "${path.module}/.terraform/openbuilder-waker.zip"
  excludes    = ["__pycache__", "__pycache__/*"]
}

data "aws_iam_policy_document" "waker_assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "waker" {
  name               = "${var.name_prefix}-waker"
  description        = "Role for the openbuilder waker Lambda: read its GitHub App credentials, start the instance."
  assume_role_policy = data.aws_iam_policy_document.waker_assume_role.json

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-waker-role"
  })
}

data "aws_iam_policy_document" "waker" {
  # 1. Its own log stream. Scoped to this function's log group.
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.waker.arn}:*"]
  }

  # 2. The GitHub App id / installation id / PEM, plus `state/last_stop`, which
  #    the flap guard reads to tell a real instance/waker disagreement from an
  #    operator who stopped the box by hand. Note it does NOT need the OpenRouter
  #    key — the waker never calls a model — but Parameter Store permissions are
  #    path-scoped, and splitting the prefix to exclude one parameter buys
  #    nothing here. Read-only: only the instance writes under `state/`.
  statement {
    sid    = "ReadOwnParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*",
    ]
  }

  # 3. Decrypt the PEM SecureString, only when SSM is the caller.
  statement {
    sid       = "DecryptSecureStringsViaSSM"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # 4. Start — never stop, never terminate, and only the tagged instance. The
  #    mirror image of the instance role's SelfStop statement.
  statement {
    sid       = "StartTaggedInstance"
    effect    = "Allow"
    actions   = ["ec2:StartInstances"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/openbuilder:managed"
      values   = ["true"]
    }
  }

  # 5. Read the instance's state and launch time (the flap guard). Describe*
  #    takes no resource-level permissions.
  statement {
    sid       = "DescribeInstance"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "waker" {
  name   = "${var.name_prefix}-waker"
  role   = aws_iam_role.waker.id
  policy = data.aws_iam_policy_document.waker.json
}

# Declared explicitly rather than letting Lambda create it implicitly: an
# implicit group never expires, and a function that logs every five minutes
# forever would otherwise accrete log storage cost indefinitely.
resource "aws_cloudwatch_log_group" "waker" {
  name              = "/aws/lambda/${var.name_prefix}-waker"
  retention_in_days = var.waker_log_retention_days

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-waker-logs"
  })
}

resource "aws_lambda_function" "waker" {
  function_name = "${var.name_prefix}-waker"
  description   = "Starts the openbuilder instance when a plan branch has no PR, or a PR is labelled changes-requested."
  role          = aws_iam_role.waker.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.13"
  architectures = ["arm64"]

  filename         = data.archive_file.waker.output_path
  source_code_hash = data.archive_file.waker.output_base64sha256

  # One installation-token call plus two GitHub calls per plan branch. 30 s is
  # generous; the ceiling exists so a hung connection cannot bill for minutes.
  timeout = 30

  # Network-bound, not memory-bound. 256 MB buys proportionally more CPU than
  # 128 MB for the RSA signature and keeps the whole month inside the free tier.
  memory_size = 256

  environment {
    variables = {
      OPENBUILDER_SSM_PREFIX         = var.ssm_prefix
      OPENBUILDER_REPOS              = join(",", var.repos)
      OPENBUILDER_INSTANCE_ID        = aws_instance.openbuilder.id
      OPENBUILDER_BRANCH_PREFIX      = "openbuilder"
      OPENBUILDER_LABEL_PREFIX       = "openbuilder"
      OPENBUILDER_FLAP_GUARD_MINUTES = tostring(var.waker_flap_guard_minutes)
    }
  }

  depends_on = [
    aws_iam_role_policy.waker,
    aws_cloudwatch_log_group.waker,
  ]

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-waker"
  })
}

# A scheduled rule is free; the invocations it triggers are far inside the
# 1M-request free tier (5-minute cadence is ~8.6k/month).
resource "aws_cloudwatch_event_rule" "waker" {
  name                = "${var.name_prefix}-waker"
  description         = "Invoke the openbuilder waker every ${var.waker_interval_minutes} minutes."
  schedule_expression = "rate(${var.waker_interval_minutes} minutes)"
  state               = var.waker_enabled ? "ENABLED" : "DISABLED"

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-waker-schedule"
  })
}

resource "aws_cloudwatch_event_target" "waker" {
  rule      = aws_cloudwatch_event_rule.waker.name
  target_id = "${var.name_prefix}-waker"
  arn       = aws_lambda_function.waker.arn
}

resource "aws_lambda_permission" "waker" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.waker.arn
}
