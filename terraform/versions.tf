terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner     = "mnour"
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "desktop"
    }
  }
}

# Token supplied via the CLOUDFLARE_API_TOKEN environment variable, never in
# a file. Scoped to Zone:DNS:Edit.
provider "cloudflare" {}
