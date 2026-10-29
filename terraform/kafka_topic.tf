# The brokers are private, so Terraform (on a laptop) can't reach them directly.
# Instead Terraform runs a one-off Job inside the cluster, which can reach MSK
# on 9094. The topic is deleted together with the MSK cluster on destroy.

locals {
  kafka_topic = {
    name       = "trades"
    partitions = 6 # max useful consumer replicas; key = symbol keeps per-symbol order
    replicas   = 2 # one copy per broker
    retention  = 86400000 # 24h in ms; Postgres is the system of record
  }
}

resource "kubernetes_job_v1" "create_topic" {
  metadata {
    name      = "create-topic-${local.kafka_topic.name}"
    namespace = "default"
  }

  spec {
    backoff_limit = 3

    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"
        node_selector  = { workload = "apps" }

        container {
          name    = "kafka-cli"
          image   = "apache/kafka:3.8.0"
          command = ["/bin/bash", "-c"]
          args = [<<-EOT
            set -euo pipefail
            echo "security.protocol=SSL" > /tmp/client.properties
            K=/opt/kafka/bin
            $K/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/client.properties \
              --create --if-not-exists --topic "$TOPIC" \
              --partitions "$PARTITIONS" --replication-factor "$REPLICAS" \
              --config retention.ms="$RETENTION_MS"
            $K/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/client.properties \
              --describe --topic "$TOPIC"
          EOT
          ]

          env {
            name  = "BOOTSTRAP"
            value = aws_msk_cluster.this.bootstrap_brokers_tls
          }
          env {
            name  = "TOPIC"
            value = local.kafka_topic.name
          }
          env {
            name  = "PARTITIONS"
            value = tostring(local.kafka_topic.partitions)
          }
          env {
            name  = "REPLICAS"
            value = tostring(local.kafka_topic.replicas)
          }
          env {
            name  = "RETENTION_MS"
            value = tostring(local.kafka_topic.retention)
          }
        }
      }
    }
  }

  # Apply fails if the topic couldn't be created, instead of failing later in the producer.
  wait_for_completion = true
  timeouts {
    create = "5m"
  }

  # Needs schedulable nodes and the broker SG rule before the pod can connect.
  depends_on = [module.eks, aws_vpc_security_group_ingress_rule.msk_from_nodes]
}
