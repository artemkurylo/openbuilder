# -----------------------------------------------------------------------------
# Secret slots
# -----------------------------------------------------------------------------
# Terraform owns the EXISTENCE of these four parameters, never their contents.
# Each carries the literal placeholder "REPLACE_ME" at create time and an
# `ignore_changes = [value]` lifecycle, so:
#
#   * `terraform apply` never overwrites a real secret you have already set;
#   * no secret value is ever written to a .tf file, a tfvars file, or state
#     beyond the placeholder.
#
# Fill them once, out of band, with the commands in the `set_secrets_commands`
# output. Rotation is the same command again — Terraform stays quiet.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "openrouter_api_key" {
  name        = "${var.ssm_prefix}/openrouter_api_key"
  description = "OpenRouter API key (sk-or-v1-...) exported as OPENROUTER_API_KEY into the omp child process."
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-openrouter-api-key"
  })
}

resource "aws_ssm_parameter" "github_app_id" {
  name        = "${var.ssm_prefix}/github_app_id"
  description = "Numeric GitHub App id for openbuilder-bot; the `iss` claim of the App JWT."
  type        = "String"
  value       = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-github-app-id"
  })
}

resource "aws_ssm_parameter" "github_app_installation_id" {
  name        = "${var.ssm_prefix}/github_app_installation_id"
  description = "Numeric installation id of openbuilder-bot on the target account; used to mint installation tokens."
  type        = "String"
  value       = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-github-app-installation-id"
  })
}

resource "aws_ssm_parameter" "github_app_private_key" {
  name        = "${var.ssm_prefix}/github_app_private_key"
  description = "Full PEM private key of the GitHub App; signs the RS256 JWT in ob-token."
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-github-app-private-key"
  })
}
