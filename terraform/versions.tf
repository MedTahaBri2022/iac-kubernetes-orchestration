terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # State is local by default. For a team, switch to a remote backend with
  # locking, for example:
  #
  # backend "s3" {
  #   bucket       = "my-terraform-state"
  #   key          = "iac-kubernetes/terraform.tfstate"
  #   region       = "eu-west-3"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

provider "aws" {
  region = var.region

  # Every resource gets the same tags without repeating them.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  # Only set when targeting a local AWS emulator (see README): the same code
  # is applied against it in CI-like conditions, without an AWS account.
  skip_credentials_validation = var.emulator_endpoint != null
  skip_metadata_api_check     = var.emulator_endpoint != null
  skip_requesting_account_id  = var.emulator_endpoint != null

  dynamic "endpoints" {
    for_each = var.emulator_endpoint == null ? [] : [var.emulator_endpoint]
    content {
      ec2 = endpoints.value
      sts = endpoints.value
    }
  }
}
