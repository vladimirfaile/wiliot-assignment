#!/usr/bin/env bash
# Provision everything and deploy the latest released app versions.
#
#   ./scripts/create.sh          # interactive terraform approvals
#   ./scripts/create.sh --yes    # no prompts
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="terraform -chdir=$ROOT/terraform"
REGION="us-east-2"
NAMESPACE="pipeline"
APPROVE=""
[[ "${1:-}" == "--yes" ]] && APPROVE="-auto-approve"

export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- prerequisites ------------------------------------------------------------
for bin in aws terraform kubectl git; do
  command -v "$bin" >/dev/null || die "$bin is not installed"
done
log "AWS identity"
aws sts get-caller-identity --query Arn --output text || die "no AWS credentials (set AWS_PROFILE?)"

# --- infrastructure -------------------------------------------------------------
log "terraform init"
$TF init -input=false

# The kubernetes provider needs a live cluster, so the first run creates
# the network and EKS on their own (no-op when they already exist).
log "terraform apply (phase 1: VPC + EKS)"
$TF apply -input=false $APPROVE -target=module.vpc -target=module.eks

log "terraform apply (phase 2: everything)"
$TF apply -input=false $APPROVE

CLUSTER="$($TF output -raw cluster_name)"
log "kubeconfig for $CLUSTER"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl get nodes -L workload

# --- applications ---------------------------------------------------------------
# Deploy the latest released version (git tag <app>-vX.Y.Z, built by CI).
# Uses a throwaway kustomize overlay, so the repo's manifests stay untouched.
deploy_app() {
  local app="$1"
  local repo_url tag version overlay
  repo_url="$($TF output -json ecr_repositories | sed -E "s/.*\"$app\":\"([^\"]+)\".*/\1/")"

  git -C "$ROOT" fetch --tags --quiet 2>/dev/null || true
  tag="$(git -C "$ROOT" tag --list "${app}-v*" --sort=-v:refname \
         | grep -E "^${app}-v[0-9]+\.[0-9]+\.[0-9]+$" | head -n1 || true)"
  if [[ -z "$tag" ]]; then
    echo "No released $app version yet: push to GitHub to let CI build it, then re-run."
    return 0
  fi
  version="${tag#"${app}-v"}"
  aws ecr describe-images --repository-name "${repo_url#*/}" --image-ids imageTag="$version" >/dev/null 2>&1 \
    || { echo "Image $app:$version not found in ECR, skipping."; return 0; }

  log "deploy $app $version"
  overlay="$(mktemp -d)"
  trap 'rm -rf "$overlay"' RETURN
  cat > "$overlay/kustomization.yaml" <<YAML
resources:
  - $ROOT/k8s/$app
images:
  - name: $app
    newName: $repo_url
    newTag: "$version"
YAML
  kubectl apply -k "$overlay"
  kubectl -n "$NAMESPACE" rollout status "deploy/$app" --timeout=180s
}

deploy_app producer
# deploy_app consumer   # enabled once the consumer exists

log "done"
kubectl -n "$NAMESPACE" get deploy,pods -o wide
