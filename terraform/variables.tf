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
