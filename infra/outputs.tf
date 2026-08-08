output "instance_id" {
  description = "EC2 instance id of the openbuilder box. Export as OPENBUILDER_INSTANCE_ID for the laptop CLI."
  value       = aws_instance.box.id
}

output "region" {
  description = "Region the box and its parameters live in. Export as OPENBUILDER_REGION for the laptop CLI."
  value       = var.region
}

output "ssm_session_command" {
  description = "Interactive shell on the box. No SSH, no key pair, no inbound rule involved."
  value       = "aws ssm start-session --target ${aws_instance.box.id} --region ${var.region}"
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

output "set_secrets_commands" {
  description = "Ready-to-paste commands that fill the parameter slots: three inline values plus the App PEM read from a file. Terraform never sees these values — it only owns the empty slots."
  value       = <<-EOT
    # 1. OpenRouter API key — https://openrouter.ai/keys
    aws ssm put-parameter --overwrite --region ${var.region} \
      --name "${aws_ssm_parameter.openrouter_api_key.name}" \
      --type SecureString \
      --value "REPLACE_ME"   # sk-or-v1-...

    # 2. GitHub App id — App settings page, "App ID"
    aws ssm put-parameter --overwrite --region ${var.region} \
      --name "${aws_ssm_parameter.github_app_id.name}" \
      --type String \
      --value "REPLACE_ME"   # e.g. 1234567

    # 3. Installation id — trailing number of the App's
    #    "Install App" -> configure URL: /settings/installations/<id>
    aws ssm put-parameter --overwrite --region ${var.region} \
      --name "${aws_ssm_parameter.github_app_installation_id.name}" \
      --type String \
      --value "REPLACE_ME"   # e.g. 87654321

    # 4. App private key — the .pem you downloaded when generating it.
    #    Kept out of your shell history by reading it from disk; delete the file
    #    afterwards.
    aws ssm put-parameter --overwrite --region ${var.region} \
      --name "${aws_ssm_parameter.github_app_private_key.name}" \
      --type SecureString \
      --value "$(cat ./openbuilder-bot.private-key.pem)"
  EOT
}
