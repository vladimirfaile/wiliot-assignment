data "aws_caller_identity" "current" {}

locals {
  cluster_name = "${var.name}-eks"

  # Account rule: every IAM role must carry this boundary.
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/CandidateBoundary"
}
