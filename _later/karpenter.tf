# IAM, SQS interruption queue and EventBridge rules for Karpenter.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.37"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true

  # Controller role, bound to the karpenter service account via Pod Identity.
  iam_role_name                     = "${var.name}-karpenter-controller"
  iam_role_use_name_prefix          = false
  iam_role_permissions_boundary_arn = local.permissions_boundary
  iam_policy_name                   = "${var.name}-karpenter-controller"
  iam_policy_use_name_prefix        = false
  enable_pod_identity               = true
  create_pod_identity_association   = true
  namespace                         = "kube-system"
  service_account                   = "karpenter"

  # Role assumed by EC2 nodes that Karpenter launches.
  node_iam_role_name                 = "${var.name}-karpenter-node"
  node_iam_role_use_name_prefix      = false
  node_iam_role_permissions_boundary = local.permissions_boundary

  # Spot interruption / rebalance events -> SQS -> Karpenter drains the node early.
  enable_spot_termination = true
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  wait       = true

  values = [yamlencode({
    serviceAccount = { name = module.karpenter.service_account }
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
  })]

  depends_on = [module.eks, module.karpenter]
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      role                       = module.karpenter.node_iam_role_name
      amiSelectorTerms           = [{ alias = "al2023@latest" }]
      subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = module.eks.cluster_name } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = module.eks.cluster_name } }]
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "default" }
          requirements = [
            # Spot preferred; on-demand is the fallback when spot capacity is unavailable.
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            # Wide instance choice = deeper spot pools = fewer interruptions.
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["c", "m", "t"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["2"] },
            { key = "karpenter.k8s.aws/instance-cpu", operator = "In", values = ["2", "4"] },
          ]
          expireAfter = "720h"
        }
      }
      limits = { cpu = "16" } # hard cap on what Karpenter may launch
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  # On destroy this is deleted first, so Karpenter terminates its EC2 nodes
  # before the controller is removed (otherwise orphaned instances block VPC teardown).
  wait       = true
  depends_on = [kubectl_manifest.karpenter_node_class]
}
