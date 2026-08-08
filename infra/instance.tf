# Canonical's public parameter always points at the current Ubuntu 24.04 LTS
# arm64 gp3 image. `nonsensitive` keeps the AMI id readable in plan output —
# it is a public value.
data "aws_ssm_parameter" "ubuntu_2404_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "box" {
  ami           = nonsensitive(data.aws_ssm_parameter.ubuntu_2404_arm64.value)
  instance_type = var.instance_type

  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # No key_name on purpose: there is no sshd path in or out of this box.

  # IMDSv2 only. hop limit 2 so the runner scripts, which call IMDS from inside
  # the instance (ob-idle-stop resolves its own instance id), still work while
  # any container on the box cannot reach it.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.tags, {
      Name = "${var.name_prefix}-root"
    })
  }

  # `shutdown -h` from inside the box (and any accidental `poweroff`) must stop
  # the instance, never terminate it. Belt-and-braces alongside the IAM policy,
  # which grants StopInstances but not TerminateInstances.
  instance_initiated_shutdown_behavior = "stop"

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    ssm_prefix         = var.ssm_prefix
    repos              = join(",", var.repos)
    control_repo       = var.control_repo
    model              = var.model
    smol_model         = var.smol_model
    max_runtime        = var.max_runtime
    max_attempts       = var.max_attempts
    idle_stop_minutes  = var.idle_stop_minutes
    git_user_name      = var.git_user_name
    git_user_email     = var.git_user_email
    region             = var.region
    omp_version        = var.omp_version
    extra_apt_packages = join(" ", var.extra_apt_packages)
  })

  # Editing user_data must not recycle a box that has live worktrees on it.
  # Config changes reach the running instance through `ob-selfupdate`.
  user_data_replace_on_change = false

  lifecycle {
    # A new Ubuntu point release changes the SSM-published AMI id. Without this
    # the next apply would silently replace the box and destroy its state.
    # Deliberate rebuilds: `terraform taint` / `-replace=aws_instance.box`.
    ignore_changes = [ami]
  }

  # First boot fetches parameters and registers with SSM, so the permissions
  # must land before the instance exists.
  depends_on = [
    aws_iam_role_policy.instance,
    aws_iam_role_policy_attachment.ssm_core,
    aws_ssm_parameter.openrouter_api_key,
    aws_ssm_parameter.github_app_id,
    aws_ssm_parameter.github_app_installation_id,
    aws_ssm_parameter.github_app_private_key,
    aws_route_table_association.public,
  ]

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-box"
  })
}
