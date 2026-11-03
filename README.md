# Binance trades → Kafka → PostgreSQL on EKS

Live Binance trades for 10 symbols are streamed over a WebSocket into Kafka (MSK)
and landed in PostgreSQL exactly once per `trade_id`. All infrastructure is
Terraform in `us-east-2`; workloads run on EKS.

> **Status:** infrastructure, producer, consumer and CI/CD are in place.
> Freshness monitoring is in place; evidence is in progress.

```
Binance WS ──► producer (EKS) ──► MSK topic "trades" ──► consumer (EKS) ──► RDS PostgreSQL
 (via NAT)      key = symbol        6 partitions, RF 2     2+ replicas       PK (symbol, trade_id)
```

## Repository layout

| Path | What |
|---|---|
| `terraform/` | VPC, EKS, MSK, RDS, ECR, GitHub OIDC role, topic Job, namespace + app config/secrets |
| `producer/` | Binance → Kafka service (Python) and Dockerfile |
| `consumer/` | Kafka → PostgreSQL service (Python) and Dockerfile |
| `monitor/` | Freshness prober: PostgreSQL → CloudWatch metrics (Python) |
| `k8s/producer/`, `k8s/consumer/`, `k8s/monitor/` | Deployments (kustomize; image set at deploy time) |
| `.github/workflows/` | `<app>-build` (SemVer build + push), `<app>-deploy` (on demand) for producer, consumer and monitor |
| `scripts/` | `create.sh`, `destroy.sh` |

## Deploy

Prerequisites: `aws` CLI (credentials for the sandbox account), `terraform >= 1.10`, `kubectl`, `git`.

```bash
export AWS_PROFILE=<your-profile>
./scripts/create.sh            # add --yes to skip approval prompts
```

The script applies Terraform in two phases (VPC + EKS first, because the
Kubernetes provider needs a live cluster), configures `kubectl`, and deploys the
latest released producer, consumer and monitor versions from ECR, and prints
the health status. Optional alarm e-mails: `terraform -chdir=terraform apply -var alert_email=you@example.com`.

**One-time GitHub setup (CI/CD):** after the first apply, add a repository
variable *Settings → Secrets and variables → Actions → Variables*:

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `terraform -chdir=terraform output -raw github_actions_role_arn` |

### Releases

Each app (`producer`, `consumer`, `monitor`) is versioned and released independently.

* **Build** — every push to `master` touching `<app>/` or `k8s/<app>/` builds an amd64 image,
  pushes it to ECR and tags the commit `<app>-vX.Y.Z`.
  First release `0.0.1`; default bump is **minor**; `[major]` / `[patch]` in the
  commit message overrides it (or choose it via *Run workflow*).
* **Deploy** — *Actions → `<app>-deploy` → Run workflow*, optional version
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

Needs only AWS credentials for the account (no cluster access):

```bash
aws cloudwatch describe-alarms --region us-east-2 --alarm-name-prefix vladimir-faile-pipeline- \
  --alarm-types CompositeAlarm MetricAlarm \
  --query '[CompositeAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp], MetricAlarms[].[AlarmName,StateValue,StateReason]][]' \
  --output text
```

`vladimir-faile-pipeline-health  OK` = trades are flowing and fresh. `ALARM` rows
say which check failed and why. (Also: `terraform -chdir=terraform output -raw health_command`.)

**Freshness target:** a trade is in PostgreSQL within **5 s** of its Binance
trade time (p99).

| Alarm | Fires when | Missing data |
|---|---|---|
| `…-pipeline-staleness` | newest row older than 30 s, 2 of 2 minutes | **breaching** (monitor or DB down = not fresh) |
| `…-pipeline-latency` | p99 trade→DB latency > 5 s, 3 of 3 minutes | not breaching (no rows = staleness alarm's job) |
| `…-pipeline-health` | either of the above (composite) | — |

The `freshness-monitor` pod queries PostgreSQL every 15 s and publishes
`StalenessSeconds`, `LatencyP99Seconds` and `RowsPerMinute` (CloudWatch namespace
`Pipeline/Trades`). It measures at the system of record and is independent of the
producer and consumer: a stalled component can't be trusted to report its own
staleness, and a dead monitor turns into missing data, which alarms.

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
* **Producer:** one replica, idempotent Kafka producer (`acks=all`),
  reconnect with exponential backoff + jitter, 30 s silence watchdog, flush on
  SIGTERM. Rolling updates start the new pod before stopping the old one
  (`maxUnavailable: 0`, readiness = WebSocket connected), so deploys leave no gap.
  Failure handling:
  * process crash / OOM: the kubelet restarts the container in place (seconds);
  * node failure: `tolerationSeconds: 30` on the not-ready/unreachable taints
    (default 300 s) gets the pod rescheduled in ~1.5 min instead of ~6 min.
  Trades during such a gap are not recovered (Binance's WebSocket has no replay).
  Considered and rejected: active-passive leader election (only helps node loss
  and drains, adds a standby and ~1 s gaps on deploys); active-active
  2 replicas (zero gap everywhere, at the cost of duplicate traffic) is the
  next step if the node-failure gap matters.
  Duplicates around reconnects/overlaps are expected; the consumer drops them.
* **Consumer (exactly-once in the DB):** reads a batch (auto-commit off), inserts
  it in one transaction with `ON CONFLICT (symbol, trade_id) DO NOTHING`, and
  commits Kafka offsets only after the DB commit. Crashes, rebalances, redeploys
  and producer resends all become re-processing that the primary key absorbs.
  `notional` is a generated column (`price * quantity`, exact `NUMERIC`);
  `ingested_at` records when the row landed. 2 replicas across AZs, PDB
  `minAvailable: 1`, cooperative-sticky rebalancing, scales to 6 (= partitions).
* **PostgreSQL:** RDS 16, `db.t4g.micro`, private, encrypted, TLS
  (`sslmode=require`), reachable only from EKS nodes.
* **CI → AWS:** GitHub OIDC, no stored keys; the role can push to the two ECR
  repos and edit only the `pipeline` namespace.

## Assumptions and shortcuts

* **Binance endpoint:** `stream.binance.com` returns HTTP 451 from `us-east-2`
  (verified from inside the cluster). The producer uses Binance's market-data
  endpoint `wss://data-stream.binance.vision` (same streams and payload);
  configurable via the `producer-config` ConfigMap.
* **Primary key is `(symbol, trade_id)`, not `trade_id` alone.** Binance trade
  ids are unique per symbol, not globally; several symbols' counters overlap, so
  `trade_id` alone would make `ON CONFLICT` silently discard real trades of
  another symbol. The `trade_id` column is kept exactly as specified.
* **`maticusdt` emits no trades.** MATIC was migrated to POL; Binance reports the
  market as halted (`exchangeInfo?symbol=MATICUSDT` → `"status": "BREAK"`, while
  `POLUSDT` is `TRADING`), so its stream connects but stays silent and the table
  has no `MATICUSDT` rows. It is kept as specified; it doesn't trip the
  producer's watchdog (any symbol's traffic counts) and freshness is measured
  on actively trading symbols. Switching to `polusdt` is a one-line change to
  `SYMBOLS` in `terraform/apps.tf`.
* **IAM:** `iam:CreatePolicy` is denied in the sandbox, so no customer-managed
  policies: EKS secrets use the default AWS-owned encryption (no customer KMS
  key), the CI role uses an inline policy, and MSK client auth is network-based
  (TLS, security group allows only EKS nodes) instead of IAM auth.
  Production: IAM auth per workload.
* **No retention in PostgreSQL.** PostgreSQL has no TTL, and the table is the
  system of record ("land every trade"), so all trades are kept. Growth is
  roughly 1–2 GB/day for 10 symbols; 20 GB storage with autoscaling to 50 GB
  covers weeks. Kafka keeps 24 h. Production: daily partitions on `trade_time`
  (`pg_partman` + `pg_cron`, both available on RDS), retention by dropping
  (or archiving to S3, then dropping) old partitions, and an alarm on RDS
  `FreeStorageSpace`.
* **DB credentials:** Terraform generates the password and passes it to the
  consumer as a Kubernetes Secret; it lives in Terraform state (S3, encrypted),
  never in Git. The app connects as the RDS master user. Production: RDS-managed
  secret or IAM DB auth via Pod Identity, and a least-privilege app role.
* **Cost/size shortcuts:** single NAT gateway (production: one per AZ);
  single-AZ RDS (production: Multi-AZ);
  2 MSK brokers (production: 3 with `min.insync.replicas=2`); on-demand app
  nodes (spot/Karpenter is a later step).
* **State locking** uses S3 native lockfiles (`use_lockfile`, Terraform ≥ 1.10);
  the provided DynamoDB table is unused because `dynamodb_table` is deprecated.
* **EKS API endpoint is public** (authenticated via IAM) so Terraform and kubectl
  work from a laptop and from GitHub-hosted runners.
