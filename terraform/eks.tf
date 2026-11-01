module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  # Public endpoint so kubectl/Terraform work from a laptop (and for the reviewers).
  # Nodes talk to the API privately inside the VPC.
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # GitHub Actions deploys apps: edit rights in the "pipeline" namespace only.
  access_entries = {
    github_actions = {
      principal_arn = aws_iam_role.github_actions.arn
      policy_associations = {
        pipeline_edit = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = { type = "namespace", namespaces = ["pipeline"] }
        }
      }
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Account naming rule + mandatory permissions boundary.
  iam_role_name                 = "${var.name}-eks-cluster"
  iam_role_use_name_prefix      = false
  iam_role_permissions_boundary = local.permissions_boundary

  # Workload AWS access uses EKS Pod Identity, so no OIDC provider/IRSA.
  enable_irsa = false

  # The sandbox user can't create customer-managed IAM policies (iam:CreatePolicy
  # is denied), so skip the two the module would create:
  # - Secrets encryption with a customer KMS key (needs a policy on the cluster role).
  #   EKS already envelope-encrypts all Kubernetes API data with an AWS-owned key
  #   by default, so a customer key is an optional extra, not a requirement.
  create_kms_key            = false
  cluster_encryption_config = {}
  # - Auto Mode tag permissions; Auto Mode isn't used here.
  enable_auto_mode_custom_tags = false

  cluster_addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    # Pin CoreDNS to the system nodes so app nodes only run apps (+ DaemonSets).
    coredns = {
      configuration_values = jsonencode({
        nodeSelector = { workload = "system" }
        tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
      })
    }
  }

  eks_managed_node_groups = {
    # Cluster add-ons (CoreDNS, later monitoring/operators). The control plane
    # itself is run by AWS; these nodes host the in-cluster system workloads.
    # Tainted so application pods can't land here.
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2 # one per AZ
      max_size     = 2
      desired_size = 2

      iam_role_name                 = "${var.name}-eks-node-system"
      iam_role_use_name_prefix      = false
      iam_role_permissions_boundary = local.permissions_boundary

      labels = { workload = "system" }
      taints = {
        critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
      }
    }

    # Producer and consumers. On-demand to start; can move to SPOT with
    # several instance types once the pipeline is proven.
    apps = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2 # one per AZ
      max_size     = 4 # headroom for consumer scale-out tests
      desired_size = 2

      iam_role_name                 = "${var.name}-eks-node-apps"
      iam_role_use_name_prefix      = false
      iam_role_permissions_boundary = local.permissions_boundary

      labels = { workload = "apps" }
    }
  }
}
