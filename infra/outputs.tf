locals {
  # Emitted commands must target the same account Terraform deployed into. Left
  # off, they would run against whatever the ambient AWS_PROFILE happens to be,
  # writing the secrets into the wrong account (or failing on AccessDenied).
  profile_flag = var.aws_profile != "" ? " --profile ${var.aws_profile}" : ""
}

output "instance_id" {
  description = "EC2 instance id of the openbuilder instance. Export as OPENBUILDER_INSTANCE_ID for the laptop CLI."
  value       = aws_instance.openbuilder.id
}

output "region" {
  description = "Region the instance and its parameters live in. Export as OPENBUILDER_REGION for the laptop CLI."
  value       = var.region
}

output "account_id" {
  description = "Account this module actually deployed into. Check it after the first apply — the fastest way to catch a wrong ambient AWS_PROFILE."
  value       = data.aws_caller_identity.current.account_id
}

output "ssm_session_command" {
  description = "Interactive shell on the instance. No SSH, no key pair, no inbound rule involved."
  value       = "aws ssm start-session --target ${aws_instance.openbuilder.id} --region ${var.region}${local.profile_flag}"
}

output "ssm_parameter_names" {
  description = "Logical secret name to SSM parameter path. The runner reads these with `aws ssm get-parameter --with-decryption`."
  value = {
    openrouter_api_key         = aws_ssm_parameter.openrouter_api_key.name
    github_app_id              = aws_ssm_parameter.github_app_id.name
    github_app_installation_id = aws_ssm_parameter.github_app_installation_id.name
    github_app_private_key     = aws_ssm_parameter.github_app_private_key.name
  }
}

output "waker" {
  description = "The scheduled power-on side of the loop: function name, cadence, and the two commands you actually need — a manual check and its logs."
  value = {
    function_name = aws_lambda_function.waker.function_name
    schedule      = aws_cloudwatch_event_rule.waker.schedule_expression
    enabled       = var.waker_enabled
    invoke        = "aws lambda invoke --region ${var.region}${local.profile_flag} --function-name ${aws_lambda_function.waker.function_name} --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout"
    logs          = "aws logs tail ${aws_cloudwatch_log_group.waker.name} --region ${var.region}${local.profile_flag} --since 1h"
  }
}

output "set_secrets_commands" {
  description = "Ready-to-paste commands that fill the parameter slots: three inline values plus the App PEM read from a file. Terraform never sees these values — it only owns the empty slots."
  value       = <<-EOT
    # 1. OpenRouter API key — https://openrouter.ai/keys
    aws ssm put-parameter --overwrite --region ${var.region}${local.profile_flag} \
      --name "${aws_ssm_parameter.openrouter_api_key.name}" \
      --type SecureString \
      --value "REPLACE_ME"   # sk-or-v1-...

    # 2. GitHub App id — App settings page, "App ID"
    aws ssm put-parameter --overwrite --region ${var.region}${local.profile_flag} \
      --name "${aws_ssm_parameter.github_app_id.name}" \
      --type String \
      --value "REPLACE_ME"   # e.g. 1234567

    # 3. Installation id — trailing number of the App's
    #    "Install App" -> configure URL: /settings/installations/<id>
    aws ssm put-parameter --overwrite --region ${var.region}${local.profile_flag} \
      --name "${aws_ssm_parameter.github_app_installation_id.name}" \
      --type String \
      --value "REPLACE_ME"   # e.g. 87654321

    # 4. App private key — the .pem you downloaded when generating it.
    #    Kept out of your shell history by reading it from disk; delete the file
    #    afterwards.
    aws ssm put-parameter --overwrite --region ${var.region}${local.profile_flag} \
      --name "${aws_ssm_parameter.github_app_private_key.name}" \
      --type SecureString \
      --value "$(cat ./openbuilder-bot.private-key.pem)"
  EOT
}
