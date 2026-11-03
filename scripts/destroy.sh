#!/usr/bin/env bash
# Tear everything down.
#
#   ./scripts/destroy.sh          # interactive terraform approval
#   ./scripts/destroy.sh --yes    # no prompt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="terraform -chdir=$ROOT/terraform"
REGION="us-east-2"
APPROVE=""
[[ "${1:-}" == "--yes" ]] && APPROVE="-auto-approve"

export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }

for bin in aws terraform kubectl; do
  command -v "$bin" >/dev/null || { echo "$bin is not installed" >&2; exit 1; }
done
aws sts get-caller-identity --query Arn --output text

$TF init -input=false >/dev/null

# --- 1. Kubernetes objects that own AWS resources ------------------------------
# LoadBalancer Services (ELBs) and PVCs (EBS volumes) are created by Kubernetes,
# not Terraform; left behind they'd block VPC deletion or leak. None are used
# today; this guards against future ones. Best effort: needs cluster access.
CLUSTER="$($TF output -raw cluster_name 2>/dev/null || true)"
if [[ -n "$CLUSTER" ]] && aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 \
   && kubectl get ns >/dev/null 2>&1; then
  log "removing app workloads and AWS-backed Kubernetes objects"
  kubectl delete -k "$ROOT/k8s/producer" --ignore-not-found --wait=true || warn "producer delete failed"
  kubectl delete -k "$ROOT/k8s/consumer" --ignore-not-found --wait=true || warn "consumer delete failed"
  kubectl delete -k "$ROOT/k8s/monitor" --ignore-not-found --wait=true || warn "monitor delete failed"
  # Local-only debug pods (not in git), if this checkout has them.
  [[ -d "$ROOT/k8s/debug" ]] && { kubectl delete -f "$ROOT/k8s/debug/" --ignore-not-found || true; }
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do [[ -n "$name" ]] && kubectl -n "$ns" delete svc "$name" --wait=true; done
  kubectl delete pvc -A --all --wait=true || true
else
  warn "no access to the cluster API; skipping in-cluster cleanup (nothing there creates AWS resources today)"
fi

# --- 2. Kubernetes objects in Terraform state ------------------------------------
# The namespace, ConfigMap and topic Job disappear with the cluster anyway.
# Dropping them from state means destroy doesn't need Kubernetes API access,
# so anyone with AWS access to the account (not only the cluster creator) can run it.
k8s_resources="$($TF state list 2>/dev/null | grep '^kubernetes_' || true)"
if [[ -n "$k8s_resources" ]]; then
  log "dropping Kubernetes-only resources from state"
  # shellcheck disable=SC2086
  $TF state rm $k8s_resources
fi

# --- 3. Everything else -------------------------------------------------------------
log "terraform destroy"
$TF destroy -input=false $APPROVE

log "remaining resources in state (should be empty)"
$TF state list || true
