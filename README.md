# Binance trades → Kafka → PostgreSQL on EKS

Live Binance trades for 10 symbols are streamed over a WebSocket into Kafka (MSK)
and landed in PostgreSQL exactly once per `trade_id`. All infrastructure is
Terraform in `us-east-2`; workloads run on EKS.

> **Status:** VPC, EKS, MSK, topic, producer and CI/CD are done.
> PostgreSQL + consumer, freshness monitoring and evidence are in progress.

```
Binance WS ──► producer (EKS) ──► MSK topic "trades" ──► consumer (EKS) ──► RDS PostgreSQL
 (via NAT)      key = symbol        6 partitions, RF 2     upsert on trade_id
```

## Repository layout

| Path | What |
|---|---|
| `terraform/` | VPC, EKS, MSK, ECR, GitHub OIDC role, topic Job, namespace + app config |
| `producer/` | Binance → Kafka service (Python) and Dockerfile |
| `k8s/producer/` | Producer Deployment (kustomize; image set at deploy time) |
| `k8s/debug/` | Throwaway network-debug pod |
| `.github/workflows/` | `producer-build` (SemVer build + push), `producer-deploy` (on demand) |
| `scripts/` | `create.sh`, `destroy.sh` |

## Deploy

Prerequisites: `aws` CLI (credentials for the sandbox account), `terraform >= 1.10`, `kubectl`, `git`.

```bash
export AWS_PROFILE=<your-profile>
./scripts/create.sh            # add --yes to skip approval prompts
```

The script applies Terraform in two phases (VPC + EKS first, because the
Kubernetes provider needs a live cluster), configures `kubectl`, and deploys the
latest released producer version from ECR.

**One-time GitHub setup (CI/CD):** after the first apply, add a repository
variable *Settings → Secrets and variables → Actions → Variables*:

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `terraform -chdir=terraform output -raw github_actions_role_arn` |

### Releases

* **Build** — every push to `master` touching `producer/` builds an amd64 image,
  pushes it to ECR and tags the commit `producer-vX.Y.Z`.
  First release `0.0.1`; default bump is **minor**; `[major]` / `[patch]` in the
  commit message overrides it (or choose it via *Run workflow*).
* **Deploy** — *Actions → producer-deploy → Run workflow*, optional version
  (empty = latest; an older version = rollback). Manifests come from the same
  git tag as the image.

## Destroy

```bash
./scripts/destroy.sh           # add --yes to skip the approval prompt
```

Removes Kubernetes objects that would own AWS resources (LoadBalancers, PVCs),
drops Kubernetes-only resources from state (they die with the cluster, so
destroy doesn't need cluster API access), then runs `terraform destroy`.

## Health check

_TBD — single command reporting data freshness against the target (step 3)._

## Evidence

_TBD — restarts, scaling, no duplicates, freshness._

## Design notes

* **Network:** private subnets in 2 AZs for nodes, MSK and RDS; one NAT gateway
  for outbound access to Binance. Nothing accepts inbound internet traffic.
* **EKS:** two managed node groups. `system` (2× t3.medium, tainted
  `CriticalAddonsOnly`) runs cluster add-ons; `apps` (2–4× t3.medium, on-demand)
  runs the producer and consumers.
* **Kafka:** MSK, 2× `kafka.t3.small`, TLS in transit, replication factor 2,
  `min.insync.replicas=1`, `unclean.leader.election.enable=false`
  (pause rather than lose data), 24 h retention. Topic `trades`: 6 partitions,
  key = symbol (per-symbol ordering, up to 6 consumers).
* **Producer:** idempotent Kafka producer (`acks=all`), reconnect with
  exponential backoff + jitter, 30 s silence watchdog, flush on SIGTERM.
  Rolling updates start the new pod before stopping the old one
  (`maxUnavailable: 0`, readiness = WebSocket connected), so deploys leave no gap.
  Duplicates around reconnects/overlaps are expected; the consumer upserts on `trade_id`.
* **CI → AWS:** GitHub OIDC, no stored keys; the role can push to the two ECR
  repos and edit only the `pipeline` namespace.

## Assumptions and shortcuts

* **Binance endpoint:** `stream.binance.com` returns HTTP 451 from `us-east-2`
  (verified from inside the cluster). The producer uses Binance's market-data
  endpoint `wss://data-stream.binance.vision` (same streams and payload);
  configurable via the `producer-config` ConfigMap.
* **`maticusdt`** was migrated to POL and may never emit trades; it is kept as
  specified and doesn't trip the producer's watchdog (any symbol's traffic counts).
* **IAM:** `iam:CreatePolicy` is denied in the sandbox, so no customer-managed
  policies: EKS secrets use the default AWS-owned encryption (no customer KMS
  key), the CI role uses an inline policy, and MSK client auth is network-based
  (TLS, security group allows only EKS nodes) instead of IAM auth.
  Production: IAM auth per workload.
* **Cost/size shortcuts:** single NAT gateway (production: one per AZ);
  2 MSK brokers (production: 3 with `min.insync.replicas=2`); on-demand app
  nodes (spot/Karpenter is a later step).
* **State locking** uses S3 native lockfiles (`use_lockfile`, Terraform ≥ 1.10);
  the provided DynamoDB table is unused because `dynamodb_table` is deprecated.
* **EKS API endpoint is public** (authenticated via IAM) so Terraform and kubectl
  work from a laptop and from GitHub-hosted runners.
