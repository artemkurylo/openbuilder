data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Instance role
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-instance"
  description        = "Role for the openbuilder EC2 instance: SSM access, its own parameters, and self-stop."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-instance-role"
  })
}

# Session Manager, the SSM agent's registration/heartbeat, and command
# execution. This is what replaces sshd.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -----------------------------------------------------------------------------
# Inline policy: exactly the five things the runner scripts do
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "instance" {
  # 1. Read its own secrets (OpenRouter key, GitHub App id / installation id /
  #    PEM) and nothing else in Parameter Store.
  statement {
    sid    = "ReadOwnParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*",
    ]
  }

  # 2. Decrypt the two SecureStrings. The AWS-managed `alias/aws/ssm` key has no
  #    stable ARN we can hardcode, so scope by service instead: this grant is
  #    only usable when SSM is the caller on the instance's behalf.
  statement {
    sid       = "DecryptSecureStringsViaSSM"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }

  # 3. Idle self-stop (ob-idle-stop). Scoped by TAG rather than by instance ARN
  #    on purpose: referencing aws_instance.openbuilder.arn here would make the role
  #    depend on the instance, which depends on the instance profile, which
  #    depends on the role — a dependency cycle. The tag condition is just as
  #    tight, and it can only ever stop, never terminate.
  statement {
    sid       = "SelfStop"
    effect    = "Allow"
    actions   = ["ec2:StopInstances"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/openbuilder:managed"
      values   = ["true"]
    }
  }

  # 4. Read-only introspection so ob-doctor and ob-idle-stop can resolve their
  #    own instance id and tags. Describe* does not support resource-level
  #    permissions.
  statement {
    sid    = "DescribeSelf"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
    ]

    resources = ["*"]
  }

  # 5. Publish run metrics (cost per job, attempts, durations). PutMetricData
  #    takes no resource ARN, so the namespace condition is the only scope.
  statement {
    sid       = "PublishOwnMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["OpenBuilder"]
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.name_prefix}-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.instance.name

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-instance-profile"
  })
}
