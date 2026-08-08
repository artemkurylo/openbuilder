# openbuilder — control plane for autonomous agentic coding.
#
# Everything here is a thin, discoverable wrapper: infrastructure lives in
# infra/ (Terraform) and every runtime operation goes through the operator CLI
# at local/bin/openbuilder. Run `make` for the target list.

TF_DIR      := infra
CLI         := local/bin/openbuilder
CONTROL_REPO ?= artemkurylo/openbuilder

# Extra arguments forwarded to the CLI, e.g. `make logs ARGS=-f`.
ARGS ?=
# Repository for `make status`, e.g. `make status REPO=artemkurylo/demo`.
REPO ?=

CACHE_DIR := $${XDG_CACHE_HOME:-$$HOME/.cache}/openbuilder

.DEFAULT_GOAL := help

.PHONY: help init plan-tf apply destroy secrets doctor shell logs status fmt lint repo-create

help: ## Show this help
	@printf 'openbuilder — control plane for autonomous agentic coding\n\n'
	@printf 'usage: make <target> [VAR=value]\n\n'
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN { FS = ":.*?## " } { printf "  %-13s %s\n", $$1, $$2 }'
	@printf '\nvariables: ARGS (forwarded to the CLI), REPO (owner/repo), CONTROL_REPO\n'
	@printf 'the CLI itself: %s help\n' '$(CLI)'

init: ## terraform init, and seed infra/terraform.tfvars from the example
	@if [ ! -f $(TF_DIR)/terraform.tfvars ]; then \
		cp $(TF_DIR)/terraform.tfvars.example $(TF_DIR)/terraform.tfvars; \
		echo "created $(TF_DIR)/terraform.tfvars — edit it before 'make apply'"; \
	else \
		echo "$(TF_DIR)/terraform.tfvars already present — leaving it alone"; \
	fi
	terraform -chdir=$(TF_DIR) init

plan-tf: ## terraform plan (named plan-tf so it never shadows `openbuilder plan`)
	terraform -chdir=$(TF_DIR) plan

apply: ## terraform apply, then drop the cached instance id
	terraform -chdir=$(TF_DIR) apply
	@rm -f "$(CACHE_DIR)/instance-id" "$(CACHE_DIR)/region"
	@echo
	@echo "next: make secrets   # then paste the put-parameter commands"
	@echo "      make doctor    # verify the instance end to end"

destroy: ## Destroy all AWS infrastructure (requires typed confirmation)
	@printf 'This destroys the openbuilder VPC, instance, EBS volume and SSM parameters.\n'
	@printf 'Local Terraform state stays in %s. Secrets are gone for good.\n' '$(TF_DIR)'
	@printf 'Type exactly "destroy openbuilder" to continue: '
	@read -r reply; \
	if [ "$$reply" != "destroy openbuilder" ]; then \
		echo "aborted."; \
		exit 1; \
	fi; \
	terraform -chdir=$(TF_DIR) destroy

secrets: ## Print the aws ssm put-parameter commands for the secrets
	@terraform -chdir=$(TF_DIR) output -raw set_secrets_commands
	@printf '\n'

doctor: ## Run ob-doctor on the instance and surface its verdict
	@$(CLI) doctor

shell: ## Open an SSM Session Manager shell on the instance
	@$(CLI) shell

logs: ## Tail the instance log over SSM (make logs ARGS=-f)
	@$(CLI) logs $(ARGS)

status: ## Show slugs, branches, PRs and labels (make status REPO=owner/repo)
	@$(CLI) status $(REPO)

fmt: ## terraform fmt -recursive
	terraform fmt -recursive

lint: ## shellcheck every shell script (skipped when shellcheck is absent)
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck not installed — skipping lint."; \
		echo "install it with: brew install shellcheck   (or: apt-get install shellcheck)"; \
		exit 0; \
	fi; \
	files=''; \
	for f in runner/bootstrap.sh $(CLI) runner/bin/*; do \
		if [ -f "$$f" ]; then files="$$files $$f"; fi; \
	done; \
	if [ -z "$$files" ]; then \
		echo "no shell scripts found — nothing to lint."; \
		exit 0; \
	fi; \
	echo "shellcheck -x -S warning$$files"; \
	shellcheck -x -S warning $$files

repo-create: ## Create the GitHub control repo and push (no-op if it exists)
	@if gh repo view '$(CONTROL_REPO)' >/dev/null 2>&1; then \
		echo "$(CONTROL_REPO) already exists — nothing to do."; \
		exit 0; \
	fi; \
	if [ ! -d .git ]; then \
		echo "git init"; \
		git init -q -b main; \
	fi; \
	if ! git rev-parse --verify HEAD >/dev/null 2>&1; then \
		git add -A; \
		git commit -q -m "openbuilder: initial control plane"; \
	fi; \
	gh repo create '$(CONTROL_REPO)' --public --source=. --remote=origin --push
	@echo
	@echo "the instance clones this repo unauthenticated at first boot, so it must stay public"
	@echo "(or ob-selfupdate has to mint an App token first) — see docs/architecture.md"
