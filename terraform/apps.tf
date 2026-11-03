# Kubernetes objects whose values come from infrastructure. The app manifests
# (k8s/) reference these, so environment-specific config never sits in Git.

resource "kubernetes_namespace_v1" "pipeline" {
  metadata {
    name = "pipeline"
  }
  depends_on = [module.eks]
}

resource "kubernetes_config_map_v1" "producer" {
  metadata {
    name      = "producer-config"
    namespace = kubernetes_namespace_v1.pipeline.metadata[0].name
  }

  data = {
    KAFKA_BOOTSTRAP         = aws_msk_cluster.this.bootstrap_brokers_tls
    KAFKA_SECURITY_PROTOCOL = "SSL"
    KAFKA_TOPIC             = local.kafka_topic.name
    BINANCE_WS_BASE         = "wss://data-stream.binance.vision"
    SYMBOLS                 = "btcusdt,ethusdt,solusdt,bnbusdt,xrpusdt,adausdt,dogeusdt,avaxusdt,linkusdt,maticusdt"
  }
}

resource "kubernetes_config_map_v1" "consumer" {
  metadata {
    name      = "consumer-config"
    namespace = kubernetes_namespace_v1.pipeline.metadata[0].name
  }

  data = {
    KAFKA_BOOTSTRAP         = aws_msk_cluster.this.bootstrap_brokers_tls
    KAFKA_SECURITY_PROTOCOL = "SSL"
    KAFKA_TOPIC             = local.kafka_topic.name
    KAFKA_GROUP_ID          = "trades-to-postgres"
    # Standard libpq variables, read by psycopg directly.
    PGHOST     = aws_db_instance.this.address
    PGPORT     = tostring(aws_db_instance.this.port)
    PGDATABASE = aws_db_instance.this.db_name
    PGUSER     = aws_db_instance.this.username
    PGSSLMODE  = "require" # encrypted connection to RDS
  }
}

resource "kubernetes_secret_v1" "consumer_db" {
  metadata {
    name      = "consumer-db"
    namespace = kubernetes_namespace_v1.pipeline.metadata[0].name
  }

  data = {
    PGPASSWORD = random_password.db.result
  }
}

resource "kubernetes_config_map_v1" "monitor" {
  metadata {
    name      = "monitor-config"
    namespace = kubernetes_namespace_v1.pipeline.metadata[0].name
  }

  data = {
    METRIC_NAMESPACE = local.metric_namespace
    AWS_REGION       = var.region
  }
}
