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

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.34"
}

variable "kafka_version" {
  description = "MSK Kafka version."
  type        = string
  default     = "3.8.x"
}

variable "github_repo" {
  description = "owner/name of the GitHub repo allowed to assume the CI role."
  type        = string
  default     = "vladimirfaile/wiliot-assignment"
}

variable "github_oidc_provider_exists" {
  description = "Set true if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}
