variable "region" {
  description = "AWS region assigned to the sandbox; calls outside it are denied."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Prefix required by the account for IAM roles, policies and S3 buckets."
  type        = string
  default     = "vladimir-faile"
}
