"""
DR Failover Lambda Handler
Triggered by EventBridge when Route 53 health check enters ALARM state.

Actions performed automatically:
  1. Promote RDS PostgreSQL read replica → standalone primary
  2. Scale up DR EKS node group (1 → 3 nodes)
  3. Publish SNS notification with failover report
  4. Log audit trail to CloudWatch
"""

import json
import boto3
import logging
import os
from datetime import datetime, timezone

log = logging.getLogger()
log.setLevel(logging.INFO)

DR_REGION             = os.environ["DR_REGION"]
DR_RDS_IDENTIFIER     = os.environ.get("DR_RDS_IDENTIFIER", "dr-platform-dr-postgres-replica")
DR_EKS_CLUSTER        = os.environ["DR_EKS_CLUSTER"]
DR_EKS_NODEGROUP      = os.environ.get("DR_EKS_NODEGROUP", "dr-platform-dr-eks-workers")
SNS_TOPIC_ARN         = os.environ["SNS_TOPIC_ARN"]


def handler(event, context):
    log.info("Failover event received: %s", json.dumps(event))

    timestamp = datetime.now(timezone.utc).isoformat()
    report = {
        "failover_initiated_at": timestamp,
        "trigger_event": event,
        "actions": []
    }

    try:
        # ── Step 1: Promote RDS Read Replica ─────────────────
        rds = boto3.client("rds", region_name=DR_REGION)
        try:
            log.info("Promoting RDS replica: %s", DR_RDS_IDENTIFIER)
            rds.promote_read_replica(
                DBInstanceIdentifier=DR_RDS_IDENTIFIER,
                BackupRetentionPeriod=7,
            )
            report["actions"].append({
                "action": "rds_promote_replica",
                "status": "initiated",
                "identifier": DR_RDS_IDENTIFIER
            })
            log.info("RDS replica promotion initiated successfully")
        except rds.exceptions.InvalidDBInstanceStateFault as e:
            # Already promoted (idempotent)
            log.warning("RDS already promoted or not in replica state: %s", e)
            report["actions"].append({
                "action": "rds_promote_replica",
                "status": "skipped",
                "reason": str(e)
            })

        # ── Step 2: Scale up DR EKS node group ───────────────
        eks = boto3.client("eks", region_name=DR_REGION)
        try:
            log.info("Scaling up DR EKS node group: %s", DR_EKS_NODEGROUP)
            eks.update_nodegroup_config(
                clusterName=DR_EKS_CLUSTER,
                nodegroupName=DR_EKS_NODEGROUP,
                scalingConfig={
                    "minSize": 2,
                    "maxSize": 4,
                    "desiredSize": 3
                }
            )
            report["actions"].append({
                "action": "eks_scale_up",
                "status": "initiated",
                "cluster": DR_EKS_CLUSTER,
                "nodegroup": DR_EKS_NODEGROUP,
                "desired_size": 3
            })
            log.info("EKS scale-up initiated successfully")
        except Exception as e:
            log.error("EKS scale-up failed: %s", e)
            report["actions"].append({
                "action": "eks_scale_up",
                "status": "failed",
                "error": str(e)
            })

        # ── Step 3: Publish SNS notification ─────────────────
        sns = boto3.client("sns", region_name="us-east-1")
        message = (
            f"[DR FAILOVER INITIATED] {timestamp}\n\n"
            f"The primary region health check has FAILED.\n"
            f"Automatic failover to DR region ({DR_REGION}) is in progress.\n\n"
            f"Actions taken:\n"
            + "\n".join([f"  • {a['action']}: {a['status']}" for a in report["actions"]])
            + f"\n\nRoute 53 DNS will automatically redirect traffic to DR region.\n"
            f"RTO target: < 5 minutes | RPO target: < 1 minute\n\n"
            f"Review CloudWatch logs for full audit trail.\n"
            f"Lambda function: {context.function_name}"
        )
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[CRITICAL] DR Failover Initiated — DR Status Monitor",
            Message=message
        )
        report["actions"].append({"action": "sns_notification", "status": "sent"})
        log.info("SNS notification sent")

        report["overall_status"] = "failover_initiated"
        log.info("Failover report: %s", json.dumps(report, indent=2))
        return {"statusCode": 200, "body": json.dumps(report)}

    except Exception as e:
        log.error("Failover handler failed: %s", e, exc_info=True)
        # Still attempt to send SNS even if steps above failed
        try:
            boto3.client("sns", region_name="us-east-1").publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject="[CRITICAL] DR Failover ERROR — Manual Intervention Required",
                Message=f"Automated failover encountered an error:\n\n{e}\n\nManual failover required immediately."
            )
        except Exception:
            pass
        raise
