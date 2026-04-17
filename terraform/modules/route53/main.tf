# ============================================================
# Route 53 Module — Health checks + automatic DNS failover
# When primary health check fails, traffic auto-routes to DR
# ============================================================

# Health check on primary ALB endpoint
resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_fqdn
  port              = 80
  type              = "HTTP"
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 10   # fast detection — 30 seconds total to failover

  tags = merge(var.tags, { Name = "${var.name}-primary-hc" })
}

# CloudWatch alarm fires when health check fails
resource "aws_cloudwatch_metric_alarm" "primary_down" {
  alarm_name          = "${var.name}-primary-endpoint-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Primary region endpoint is unhealthy — DR failover initiated"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }

  tags = var.tags
}

# Primary DNS record — active when healthy
resource "aws_route53_record" "primary" {
  zone_id = var.hosted_zone_id
  name    = var.dns_name
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = true
  }

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary.id
  set_identifier  = "primary"
}

# DR DNS record — takes over automatically when primary fails
resource "aws_route53_record" "dr" {
  zone_id = var.hosted_zone_id
  name    = var.dns_name
  type    = "A"

  alias {
    name                   = var.dr_alb_dns
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = true
  }

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier = "dr"
}

# EventBridge rule: CloudWatch alarm → Lambda failover
resource "aws_cloudwatch_event_rule" "dr_trigger" {
  name        = "${var.name}-dr-trigger"
  description = "Trigger DR Lambda when primary health check fails"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.primary_down.alarm_name]
      state     = { value = ["ALARM"] }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "lambda_failover" {
  rule      = aws_cloudwatch_event_rule.dr_trigger.name
  target_id = "FailoverLambda"
  arn       = var.failover_lambda_arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.failover_lambda_arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dr_trigger.arn
}
