terraform {
  # Amended from the spec's ">= 1.9": the operator's local Terraform is v1.7.4
  # and nothing in this module uses a 1.8+/1.9+ feature (no provider-defined
  # functions, no cross-variable validation, no `templatestring`).
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # ---------------------------------------------------------------------------
  # State backend
  # ---------------------------------------------------------------------------
  # Default is the local backend: this stack is one instance in one personal
  # account, driven from one laptop, so `terraform.tfstate` next to the code is
  # the boring correct choice. Note that state DOES contain the SSM parameter
  # placeholders — never the real secret values, which are written out-of-band
  # with `aws ssm put-parameter` (see the `set_secrets_commands` output).
  #
  # To migrate to remote state later:
  #   1. Create the bucket and lock table once, by hand:
  #        aws s3api create-bucket --bucket openbuilder-tfstate-REPLACE_ME \
  #          --region us-east-1
  #        aws s3api put-bucket-versioning --bucket openbuilder-tfstate-REPLACE_ME \
  #          --versioning-configuration Status=Enabled
  #        aws dynamodb create-table --table-name openbuilder-tflock \
  #          --attribute-definitions AttributeName=LockID,AttributeType=S \
  #          --key-schema AttributeName=LockID,KeyType=HASH \
  #          --billing-mode PAY_PER_REQUEST --region us-east-1
  #   2. Uncomment the block below and fill in the bucket name.
  #   3. Run `terraform init -migrate-state` and answer "yes" when it offers to
  #      copy the existing local state up.
  #   4. Delete the local `terraform.tfstate*` files afterwards.
  #
  # backend "s3" {
  #   bucket         = "openbuilder-tfstate-REPLACE_ME"
  #   key            = "openbuilder/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "openbuilder-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  # The common pair from the naming contract goes on every resource this
  # provider creates. The per-resource `Name` tag is set on each resource.
  default_tags {
    tags = local.tags
  }
}
