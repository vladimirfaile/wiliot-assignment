# Freshness monitoring.
#
# Target: a trade lands in PostgreSQL within 5 s of its Binance trade time (p99).
# The freshness-monitor pod (monitor/) queries the DB every 15 s and publishes
# StalenessSeconds, LatencyP99Seconds and RowsPerMinute to CloudWatch.
# One composite alarm = one health answer: OK / ALARM.

locals {
  metric_namespace  = "Pipeline/Trades"
  metric_dimensions = { Pipeline = "trades" }
}

# --- IAM for the monitor pod (EKS Pod Identity) -------------------------------
resource "aws_iam_role" "monitor" {
  name                 = "${var.name}-freshness-monitor"
  permissions_boundary = local.permissions_boundary

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# Inline (iam:CreatePolicy is denied). Only PutMetricData, only our namespace.
resource "aws_iam_role_policy" "monitor" {
  name = "${var.name}-freshness-monitor"
  role = aws_iam_role.monitor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*" # PutMetricData has no resource ARN; scoped by namespace below
      Condition = { StringEquals = { "cloudwatch:namespace" = local.metric_namespace } }
    }]
  })
}

resource "aws_eks_pod_identity_association" "monitor" {
  cluster_name    = module.eks.cluster_name
  namespace       = "pipeline"
  service_account = "freshness-monitor"
  role_arn        = aws_iam_role.monitor.arn
}

# --- Alerting -------------------------------------------------------------------
# Optional e-mail notifications: terraform apply -var alert_email=you@example.com
# (AWS sends a confirmation link first).
resource "aws_sns_topic" "alerts" {
  count = var.alert_email == "" ? 0 : 1
  name  = "${var.name}-pipeline-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarm_actions = var.alert_email == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

# Pipeline stalled: newest row older than 30 s for 2 consecutive minutes.
# Missing data = breaching: if the monitor or the DB is down, we can't claim freshness.
resource "aws_cloudwatch_metric_alarm" "staleness" {
  alarm_name          = "${var.name}-pipeline-staleness"
  alarm_description   = "No new trades in PostgreSQL for >30s (2 of 2 minutes)."
  namespace           = local.metric_namespace
  metric_name         = "StalenessSeconds"
  dimensions          = local.metric_dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 30
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Data arrives but late: p99 trade->DB latency above the 5 s target for 3 minutes.
# Missing = not breaching: no rows at all is the staleness alarm's job.
resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name          = "${var.name}-pipeline-latency"
  alarm_description   = "p99 trade->PostgreSQL latency above the 5s target (3 of 3 minutes)."
  namespace           = local.metric_namespace
  metric_name         = "LatencyP99Seconds"
  dimensions          = local.metric_dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# The single health answer for humans and reviewers.
resource "aws_cloudwatch_composite_alarm" "health" {
  alarm_name        = "${var.name}-pipeline-health"
  alarm_description = "Pipeline unhealthy: data stale or freshness target missed."
  alarm_rule        = "ALARM(\"${aws_cloudwatch_metric_alarm.staleness.alarm_name}\") OR ALARM(\"${aws_cloudwatch_metric_alarm.latency.alarm_name}\")"
  alarm_actions     = local.alarm_actions
  ok_actions        = local.alarm_actions
}
