# Kafka for the trade stream: Amazon MSK, 2 brokers (one per private subnet/AZ).
#
# Auth: TLS in transit, no client auth; access is restricted to the EKS nodes
# by security group. IAM auth would need a customer-managed IAM policy
# (iam:CreatePolicy is denied in this sandbox); SASL/SCRAM would add Secrets
# Manager + a KMS key. Documented as a shortcut in the README.

resource "aws_security_group" "msk" {
  name        = "${var.name}-msk"
  description = "MSK brokers: TLS from EKS nodes only"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_nodes" {
  security_group_id            = aws_security_group.msk.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 9094 # TLS listener
  to_port                      = 9094
  description                  = "Kafka TLS from EKS nodes"
}

resource "aws_msk_configuration" "this" {
  name           = "${var.name}-kafka"
  kafka_versions = [var.kafka_version]

  server_properties = <<-PROPS
    # Topics are created explicitly (k8s/kafka/create-topic.yaml), never by typo.
    auto.create.topics.enable=false
    default.replication.factor=2
    # 2 brokers: requiring 2 in-sync replicas would stop writes during a broker
    # restart/patch. 1 keeps ingesting; acks=all still waits for all *in-sync* replicas.
    min.insync.replicas=1
    log.retention.hours=24
  PROPS

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.name}-kafka"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.t3.small" # smallest MSK size; load is ~10s-100s msgs/s
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 20 # GiB; 24h retention of trades is well below this
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
    # At rest: AWS-managed key (default), no customer KMS key to manage/delete.
  }

  client_authentication {
    unauthenticated = true
  }
}
