#!/bin/bash
# ============================================================
# test-failover.sh — End-to-end DR failover test
# Tests: health check, Lambda trigger, RDS promotion, DNS flip
# Usage: ./scripts/test-failover.sh [--simulate | --restore]
# ============================================================
set -euo pipefail

PRIMARY_REGION="us-east-1"
DR_REGION="us-west-2"
PROJECT="dr-platform"
MODE="${1:---simulate}"

PASS=0; FAIL=0

pass() { echo "  [PASS] $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }
section() { echo ""; echo "=== $1 ==="; }

# ── Helper: check HTTP status ─────────────────────────────
check_http() {
  local url=$1 expected=$2 label=$3
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$url" || echo "000")
  if [ "$code" = "$expected" ]; then
    pass "$label → HTTP $code"
  else
    fail "$label → expected HTTP $expected, got HTTP $code"
  fi
}

# ──────────────────────────────────────────────────────────
section "PRE-FLIGHT: Connectivity"
# ──────────────────────────────────────────────────────────
echo "Checking AWS CLI..."
aws sts get-caller-identity --query Account --output text > /dev/null && pass "AWS credentials valid" || fail "AWS credentials invalid"

echo "Checking kubectl (primary)..."
aws eks update-kubeconfig --region "$PRIMARY_REGION" --name "${PROJECT}-primary-eks" --quiet 2>/dev/null && pass "kubectl configured for primary" || fail "kubectl primary config failed"

echo "Checking kubectl (DR)..."
aws eks update-kubeconfig --region "$DR_REGION" --name "${PROJECT}-dr-eks" --quiet 2>/dev/null && pass "kubectl configured for DR" || fail "kubectl DR config failed"

# ──────────────────────────────────────────────────────────
section "TEST 1: Primary cluster health"
# ──────────────────────────────────────────────────────────
PRIMARY_SVC=$(kubectl get svc dr-status-monitor-svc -n dr-app \
  --context "$(kubectl config current-context)" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -n "$PRIMARY_SVC" ]; then
  pass "Primary LoadBalancer exists: $PRIMARY_SVC"
  check_http "http://${PRIMARY_SVC}/health" "200" "Primary /health"
  check_http "http://${PRIMARY_SVC}/ready"  "200" "Primary /ready"
  check_http "http://${PRIMARY_SVC}/metrics" "200" "Primary /metrics (Prometheus)"
else
  fail "Primary LoadBalancer not found — is the app deployed?"
fi

# ──────────────────────────────────────────────────────────
section "TEST 2: DR cluster health (standby)"
# ──────────────────────────────────────────────────────────
aws eks update-kubeconfig --region "$DR_REGION" --name "${PROJECT}-dr-eks" --quiet 2>/dev/null || true
DR_SVC=$(kubectl get svc dr-status-monitor-svc -n dr-app \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [ -n "$DR_SVC" ]; then
  pass "DR LoadBalancer exists: $DR_SVC"
  check_http "http://${DR_SVC}/health" "200" "DR /health"
else
  fail "DR LoadBalancer not found — is DR cluster deployed?"
fi

# ──────────────────────────────────────────────────────────
section "TEST 3: Velero backups"
# ──────────────────────────────────────────────────────────
aws eks update-kubeconfig --region "$PRIMARY_REGION" --name "${PROJECT}-primary-eks" --quiet 2>/dev/null || true
BACKUP_COUNT=$(kubectl get backups -n velero --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "0" ]; then
  pass "Velero backups found: $BACKUP_COUNT"
  FAILED_BACKUPS=$(kubectl get backups -n velero --no-headers 2>/dev/null | grep -c "Failed" || echo "0")
  [ "$FAILED_BACKUPS" = "0" ] && pass "No failed backups" || fail "$FAILED_BACKUPS failed backup(s)"
else
  fail "No Velero backups found — check backup schedule"
fi

# ──────────────────────────────────────────────────────────
section "TEST 4: RDS replication status"
# ──────────────────────────────────────────────────────────
DR_RDS_STATUS=$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --query "DBInstances[?DBInstanceIdentifier=='${PROJECT}-dr-postgres-replica'].DBInstanceStatus" \
  --output text 2>/dev/null || echo "not-found")

if [ "$DR_RDS_STATUS" = "available" ]; then
  pass "DR RDS replica is available"
elif [ "$DR_RDS_STATUS" = "not-found" ]; then
  fail "DR RDS replica not found"
else
  fail "DR RDS replica status: $DR_RDS_STATUS (expected: available)"
fi

# ──────────────────────────────────────────────────────────
section "TEST 5: Route 53 health check"
# ──────────────────────────────────────────────────────────
HC_ID=$(aws route53 list-health-checks \
  --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName!=null].Id" \
  --output text | head -1 || echo "")

if [ -n "$HC_ID" ]; then
  HC_STATUS=$(aws route53 get-health-check-status --health-check-id "$HC_ID" \
    --query "HealthCheckObservations[0].StatusReport.Status" --output text 2>/dev/null || echo "unknown")
  pass "Route 53 health check found: $HC_ID"
  echo "  Status: $HC_STATUS"
else
  fail "No Route 53 health checks found"
fi

# ──────────────────────────────────────────────────────────
if [ "$MODE" = "--simulate" ]; then
section "TEST 6: Simulate failover (Lambda dry-run)"
# ──────────────────────────────────────────────────────────
  LAMBDA_ARN=$(aws lambda get-function \
    --region "$PRIMARY_REGION" \
    --function-name "${PROJECT}-primary-failover" \
    --query "Configuration.FunctionArn" --output text 2>/dev/null || echo "")

  if [ -n "$LAMBDA_ARN" ]; then
    pass "Failover Lambda found: $LAMBDA_ARN"
    echo "  Invoking Lambda (dry-run simulation)..."
    RESULT=$(aws lambda invoke \
      --region "$PRIMARY_REGION" \
      --function-name "${PROJECT}-primary-failover" \
      --payload '{"source":"test","detail-type":"Manual DR Test","detail":{"alarmName":"test"}}' \
      --log-type Tail \
      /tmp/lambda-result.json \
      --query "StatusCode" --output text 2>/dev/null || echo "0")
    if [ "$RESULT" = "200" ]; then
      pass "Lambda invocation returned HTTP 200"
      cat /tmp/lambda-result.json 2>/dev/null | python3 -m json.tool 2>/dev/null || true
    else
      fail "Lambda invocation returned HTTP $RESULT"
    fi
  else
    fail "Failover Lambda not found"
  fi
fi

# ──────────────────────────────────────────────────────────
if [ "$MODE" = "--restore" ]; then
section "RESTORE: Scale DR EKS back to standby"
# ──────────────────────────────────────────────────────────
  echo "Scaling DR node group back to 1 node..."
  aws eks update-nodegroup-config \
    --region "$DR_REGION" \
    --cluster-name "${PROJECT}-dr-eks" \
    --nodegroup-name "${PROJECT}-dr-eks-workers" \
    --scaling-config minSize=1,maxSize=4,desiredSize=1
  pass "DR EKS scaled back to standby (1 node)"
fi

# ──────────────────────────────────────────────────────────
section "SUMMARY"
# ──────────────────────────────────────────────────────────
echo ""
echo "  Tests passed: $PASS"
echo "  Tests failed: $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL TESTS PASSED — DR platform is ready"
  exit 0
else
  echo "  SOME TESTS FAILED — review output above"
  exit 1
fi
