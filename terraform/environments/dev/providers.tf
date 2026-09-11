terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.0"
    }
  }

  # Remote state + locking. Comment this block out to use local state while
  # you learn (Day 12 explains the trade-off, and why locking matters).
  #
  # backend "s3" {
  #   bucket         = "my-tfstate-bucket"
  #   key            = "newrelic-fleet/dev/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
      CostCenter  = var.cost_center
    }
  }
}

provider "newrelic" {
  account_id = var.newrelic_account_id
  region     = var.newrelic_region
  # API key comes from NEW_RELIC_API_KEY, never from a committed file.
}
