terraform {
  required_version = ">= 1.10" # S3 native state locking (use_lockfile)

  backend "s3" {
    bucket       = "vladimir-faile-tfstate-092988563851"
    key          = "infra/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
