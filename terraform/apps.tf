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
