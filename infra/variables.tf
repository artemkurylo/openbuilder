# -----------------------------------------------------------------------------
# Placement
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region hosting the openbuilder instance and its SSM parameters."
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  # Terraform obeys the ambient AWS_PROFILE, which is often pinned to a totally
  # different account — e.g. one that only serves a model API. Applying this
  # module there fails on ec2:* at best, and builds the instance in the wrong
  # account at worst. Pin the intended account here and the mistake is
  # impossible. Empty means "use the normal AWS credential chain".
  description = "AWS profile to deploy with. Empty uses the default credential chain (AWS_PROFILE, env keys, SSO, instance role)."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix for every resource name and for the `Name` tag (`<name_prefix>-<resource>`)."
  type        = string
  default     = "openbuilder"
}

# -----------------------------------------------------------------------------
# Instance shape
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. Graviton (t4g/c7g/...) and x86 (t3/m5/...) both work; the AMI architecture and the omp binary are both derived from this value."
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_gb" {
  # gp3 storage is billed 24/7 on provisioned size, whether the instance is
  # running or stopped — idle auto-stop does NOT reduce it. At ~$0.095/GB-month
  # in eu-central-1 this is the single largest fixed cost, so keep it small:
  # 40 GiB holds the Ubuntu image, the omp binary (~154 MB), a repo clone, its
  # worktrees and node_modules with room to spare. Raise it only if ob-doctor's
  # disk check starts warning.
  description = "Size of the encrypted gp3 root volume in GiB. Holds target-repo clones, worktrees and node_modules. Billed 24/7 regardless of instance state."
  type        = number
  default     = 40
}

# -----------------------------------------------------------------------------
# Runtime configuration rendered into /opt/openbuilder/etc/openbuilder.env
# -----------------------------------------------------------------------------

variable "ssm_prefix" {
  description = "SSM Parameter Store prefix for openbuilder secrets. Leading slash, no trailing slash."
  type        = string
  default     = "/openbuilder"

  validation {
    condition     = can(regex("^/[a-zA-Z0-9._/-]*[a-zA-Z0-9._-]$", var.ssm_prefix))
    error_message = "ssm_prefix must start with '/' and must not end with '/'."
  }
}

variable "repos" {
  description = "Target repositories the remote agent is allowed to work on, as `owner/repo`. Rendered into OPENBUILDER_REPOS."
  type        = list(string)

  validation {
    condition     = length(var.repos) > 0 && alltrue([for r in var.repos : can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", r))])
    error_message = "repos must be a non-empty list of `owner/repo` strings."
  }
}

variable "control_repo" {
  description = "The openbuilder control repository itself, as `owner/repo`. Cloned to /opt/openbuilder/repo for self-update."
  type        = string
  default     = "artemkurylo/openbuilder"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.control_repo))
    error_message = "control_repo must be an `owner/repo` string."
  }
}

variable "model" {
  description = "omp model selector used for implementation and review-response runs on the instance."
  type        = string
  default     = "openrouter/deepseek/deepseek-v4-flash-0731"
}

variable "smol_model" {
  description = "omp model selector for cheap auxiliary calls (summaries, title generation) on the instance."
  type        = string
  default     = "openrouter/deepseek/deepseek-v4-flash-0731"
}

variable "max_runtime" {
  description = "Wall-clock ceiling for a single omp run, in omp `--max-time` duration form (e.g. 45m, 2h)."
  type        = string
  default     = "45m"

  validation {
    condition     = can(regex("^[0-9]+(s|m|h)$", var.max_runtime))
    error_message = "max_runtime must be a duration like 90s, 45m or 2h."
  }
}

variable "max_attempts" {
  description = "How many times the instance may attempt one slug before it self-labels `openbuilder:blocked`."
  type        = number
  default     = 6
}

variable "idle_stop_minutes" {
  description = "Minutes of no work and no filesystem activity before the instance stops itself."
  type        = number
  default     = 30
}

variable "git_user_name" {
  description = "git user.name used for commits pushed by the remote agent."
  type        = string
  default     = "openbuilder-bot"
}

variable "git_user_email" {
  description = "git user.email used for commits pushed by the remote agent."
  type        = string
  default     = "openbuilder-bot@users.noreply.github.com"
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the dedicated openbuilder VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the single public subnet the instance lives in."
  type        = string
  default     = "10.42.1.0/24"
}

# -----------------------------------------------------------------------------
# Cost guardrails
# -----------------------------------------------------------------------------

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget in USD. Alerts fire at 80% and 100% of actual spend. NOTE: this covers AWS only — OpenRouter model spend is billed by OpenRouter and is invisible to AWS Budgets."
  type        = number
  default     = 20
}

variable "budget_alert_email" {
  description = "Email address for budget alerts. Empty string disables the budget entirely."
  type        = string
  default     = ""
}

variable "enable_budget" {
  description = "Create the monthly cost budget. Requires a non-empty budget_alert_email to take effect."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Bootstrap inputs
# -----------------------------------------------------------------------------

variable "omp_version" {
  description = "omp release to install on the instance. `latest` tracks the newest GitHub release; otherwise a tag like v17.2.11."
  type        = string
  default     = "latest"
}

variable "extra_apt_packages" {
  description = "Additional apt packages bootstrap.sh installs on top of its baseline set (toolchains your target repos need)."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Waker (power-on side of the loop; see waker.tf)
# -----------------------------------------------------------------------------

variable "waker_enabled" {
  description = "Run the scheduled waker. False disables the EventBridge rule and leaves power-on to the laptop CLI; the Lambda stays deployed and manually invokable."
  type        = bool
  default     = true
}

variable "waker_interval_minutes" {
  description = "How often the waker checks GitHub for actionable work. This is the worst-case delay between labelling a PR `openbuilder:changes-requested` and the instance booting."
  type        = number
  default     = 5

  validation {
    condition     = var.waker_interval_minutes >= 1 && var.waker_interval_minutes <= 60
    error_message = "waker_interval_minutes must be between 1 and 60."
  }
}

variable "waker_flap_guard_minutes" {
  description = "Refuse to start the instance if it was launched fewer than this many minutes ago and is already stopped again. Must stay below idle_stop_minutes, otherwise it would block legitimate wakes."
  type        = number
  default     = 20

  validation {
    condition     = var.waker_flap_guard_minutes >= 0
    error_message = "waker_flap_guard_minutes cannot be negative."
  }
}

variable "waker_log_retention_days" {
  description = "CloudWatch retention for the waker's log group. It logs a few lines every interval, forever, so unlimited retention is a slow leak."
  type        = number
  default     = 14
}


# -----------------------------------------------------------------------------
# Derived values
# -----------------------------------------------------------------------------

locals {
  # Applied to every resource, both via the provider's `default_tags` and via an
  # explicit merge on each resource. `openbuilder:managed` is load-bearing: the
  # instance's own IAM policy allows ec2:StopInstances only against resources
  # carrying this tag (see iam.tf).
  tags = {
    "openbuilder:managed" = "true"
    "Project"             = "openbuilder"
  }
}
