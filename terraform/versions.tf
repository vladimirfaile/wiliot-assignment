terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "wiliot-assignment"
      Owner     = "vladimir-faile"
      ManagedBy = "terraform"
    }
  }
}
