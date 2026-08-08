# The omp release asset and the AMI must agree with the instance type's CPU
# architecture, otherwise the instance boots an image it cannot run (or runs an
# unrunnable omp binary). instance_type is a variable, so derive the arch from
# it instead of pinning arm64 and hoping nobody edits it. runner/bootstrap.sh
# performs the mirror-image detection via `uname -m`.
locals {
  instance_family = split(".", var.instance_type)[0]

  # Graviton families carry a `g` in the generation suffix: t4g, c7g, m7gd,
  # x2gd, im4gn, c6gn. Anything else is Intel/AMD, which Canonical calls amd64.
  ami_architecture = can(regex("^[a-z]+[0-9]+[a-z]*g[a-z]*$", local.instance_family)) ? "arm64" : "amd64"
}

# Canonical's public parameter always points at the current Ubuntu 24.04 LTS
# gp3 image for the selected architecture. `nonsensitive` keeps the AMI id
# readable in plan output — it is a public value.
data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/${local.ami_architecture}/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "openbuilder" {
  ami           = nonsensitive(data.aws_ssm_parameter.ubuntu_2404.value)
  instance_type = var.instance_type

  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # No key_name on purpose: there is no sshd path in or out of this instance.

  # IMDSv2 only. hop limit 2 so the runner scripts, which call IMDS from inside
  # the instance (ob-idle-stop resolves its own instance id), still work while
  # any container on the instance cannot reach it.
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

  # `shutdown -h` from inside the instance (and any accidental `poweroff`) must stop
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

  # Editing user_data must not recycle a instance that has live worktrees on it.
  # Config changes reach the running instance through `ob-selfupdate`.
  user_data_replace_on_change = false

  lifecycle {
    # A new Ubuntu point release changes the SSM-published AMI id. Without this
    # the next apply would silently replace the instance and destroy its state.
    # Deliberate rebuilds: `terraform taint` / `-replace=aws_instance.openbuilder`.
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
    Name = var.name_prefix
  })
}
