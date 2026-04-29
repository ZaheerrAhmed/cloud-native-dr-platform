# Component Testing Guide — Phoenix DR Platform

> Run each test in order. Each section tells you what to run, what to expect, and what PASS looks like.

---

## QUICK VARIABLES (set these once, use everywhere)

```bash
PRIMARY_LB="a226966b5218e4a25ac3c61ccc08d58b-1999881320.us-east-1.elb.amazonaws.com"
DR_LB="a0540203aef364452b419e90298fab45-590619815.us-west-2.elb.amazonaws.com"
HC_ID="d7a6a372-a27e-496d-86b6-f6fe7a10de0b"
GRAFANA_URL="http://a0b2fe304029b4e33a5f96c00d909abb-1112333123.us-east-1.elb.amazonaws.com"
```

---

## TEST 1 — Primary Application

```bash
curl -s http://$PRIMARY_LB/health | python3 -m json.tool
curl -s http://$PRIMARY_LB/status | python3 -m json.tool
curl -s http://$PRIMARY_LB/
```

**PASS:**
- `status: "healthy"`
- `region: "us-east-1"`
- `environment: "primary"`
- `database.role: "primary"`
- `database.status: "healthy"`

---

## TEST 2 — DR Application

```bash
curl -s http://$DR_LB/health | python3 -m json.tool
curl -s http://$DR_LB/status | python3 -m json.tool
```

**PASS:**
- `status: "healthy"`
- `region: "us-west-2"`
- `environment: "dr"`
- `database.role: "replica"`
- `database.status: "healthy"`

---

## TEST 3 — Kubernetes Clusters

```bash
# Primary cluster
kubectl get nodes --context primary
kubectl get pods -n dr-app --context primary
kubectl get svc -n dr-app --context primary

# DR cluster
kubectl get nodes --context dr
kubectl get pods -n dr-app --context dr
kubectl get svc -n dr-app --context dr
```

**PASS:**
- Primary: 2 nodes `Ready`, 2 pods `Running 1/1`
- DR: 1 node `Ready`, 1-2 pods `Running 1/1`

---

## TEST 4 — RDS Replication

```bash
# Primary RDS — should show is_replica: false
curl -s http://$PRIMARY_LB/status | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('Primary DB role:', d['database']['role'])"

# DR RDS — should show is_replica: true
curl -s http://$DR_LB/status | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('DR DB role:', d['database']['role'])"

# Confirm via AWS CLI
aws rds describe-db-instances \
  --db-instance-identifier dr-platform-primary-postgres \
  --region us-east-1 \
  --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output table

aws rds describe-db-instances \
  --db-instance-identifier dr-platform-dr-postgres-replica \
  --region us-west-2 \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output table
```

**PASS:**
- Primary: `role: primary`, status `available`
- DR: `role: replica`, source = primary ARN

---

## TEST 5 — Route53 Health Check

```bash
# All checkers should return Success HTTP 200
aws route53 get-health-check-status \
  --health-check-id $HC_ID \
  --query 'HealthCheckObservations[*].StatusReport.Status' \
  --output text | tr '\t' '\n' | sort | uniq -c

# CloudWatch alarm should be OK
aws cloudwatch describe-alarms \
  --alarm-names "dr-platform-primary-primary-endpoint-down" \
  --region us-east-1 \
  --query 'MetricAlarms[0].[StateValue]' --output text
```

**PASS:**
- All health check observations show `Success: HTTP Status Code 200`
- CloudWatch alarm state: `OK`

---

## TEST 6 — ECR Repository

```bash
aws ecr describe-images \
  --repository-name dr-platform/dr-status-monitor \
  --region us-east-1 \
  --query 'imageDetails[*].[imageTags[0],imagePushedAt,imageSizeInBytes]' \
  --output table
```

**PASS:**
- Shows `latest` tag with a recent push date

---

## TEST 7 — S3 Cross-Region Replication

```bash
# Upload a test file to primary bucket
echo "test-$(date)" | aws s3 cp - s3://dr-platform-primary-velero-primary/test-crr.txt

# Wait 30 seconds, then check if it replicated to DR bucket
sleep 30
aws s3 ls s3://dr-platform-primary-velero-dr/test-crr.txt

# Clean up
aws s3 rm s3://dr-platform-primary-velero-primary/test-crr.txt
```

**PASS:**
- File appears in DR bucket within 30-60 seconds

---

## TEST 8 — Lambda Failover Function

```bash
# Check Lambda exists and is configured
aws lambda get-function \
  --function-name dr-platform-primary-failover \
  --region us-east-1 \
  --query 'Configuration.[FunctionName,Runtime,State,Handler]' --output table

# Check environment variables are set correctly
aws lambda get-function-configuration \
  --function-name dr-platform-primary-failover \
  --region us-east-1 \
  --query 'Environment.Variables' --output table
```

**PASS:**
- State: `Active`
- Runtime: `python3.12`
- Variables: `DR_REGION=us-west-2`, `DR_EKS_CLUSTER=dr-platform-dr-eks`

---

## TEST 9 — SNS Alert

```bash
# Send a test SNS message manually
aws sns publish \
  --topic-arn "arn:aws:sns:us-east-1:380093117517:dr-platform-primary-dr-alerts" \
  --subject "DR Platform - Test Alert" \
  --message "This is a test alert from the DR platform. If you receive this, SNS is working correctly." \
  --region us-east-1
```

**PASS:**
- Email arrives at `zaheer.noor210@gmail.com` within 1-2 minutes
- NOTE: You must first confirm the subscription link sent to that email

---

## TEST 10 — Prometheus & Grafana (Monitoring)

### Start port-forward
```bash
# VM
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 --context primary &

# Windows PowerShell SSH tunnel
# ssh -L 9090:localhost:9090 zaheer@192.168.88.130
```

### Verify Prometheus scrape targets are UP
```bash
curl -s 'http://localhost:9090/api/v1/query?query=up' | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['result']
for m in data:
    print(m['metric'].get('job','?'), '→', 'UP' if m['value'][1]=='1' else 'DOWN')
"
```

**PASS:** Jobs listed as UP: `dr-status-monitor`, `node-exporter`, `kube-state-metrics`

### Verify Prometheus alert rules are loaded
```bash
curl -s 'http://localhost:9090/api/v1/rules' | \
  python3 -c "
import sys, json
groups = json.load(sys.stdin)['data']['groups']
for g in groups:
    for r in g['rules']:
        print(r['name'])
"
```

**PASS:** Should include: `AppDown`, `DatabaseUnreachable`, `NodeMemoryHigh`, `PodCrashLooping`, `VeleroBackupFailed`

### Verify Grafana dashboards
```
URL: http://a0b2fe304029b4e33a5f96c00d909abb-1112333123.us-east-1.elb.amazonaws.com
Login: admin / Admin@DR2024!
```

Navigate to **Dashboards → DR Platform** folder. Expected dashboards:

| Dashboard | What it shows |
|---|---|
| Kubernetes Cluster | Cluster-level CPU, memory, pod count |
| Node Exporter | Per-node CPU, memory, disk I/O, network |
| Velero | Backup success/failure count, schedule status |
| Kubernetes Views - Pods | Per-pod CPU + memory usage over time |
| Kubernetes Views - Namespaces | Resource consumption per namespace |
| Kubernetes Views - Global | Full cluster overview with all nodes |
| Kubernetes Networking | Network in/out per pod and namespace |
| CoreDNS | DNS query rate, latency, errors |
| Kubernetes PVC | PersistentVolume capacity and usage % |

### Check node memory metric directly
```bash
curl -s 'http://localhost:9090/api/v1/query?query=(1-(node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes))*100' | \
  python3 -c "
import sys, json
for m in json.load(sys.stdin)['data']['result']:
    print('Node memory used %:', round(float(m['value'][1]),1))
"
```

**PASS:** Returns a value between 0-100 for each node

---

## TEST 11 — OpenSearch SIEM (Log Aggregation)

### Start port-forwards
```bash
# VM
kubectl port-forward svc/opensearch-cluster-master -n logging 9200:9200 --context primary &
kubectl port-forward svc/opensearch-dashboards -n logging 5601:5601 --context primary &

# Windows PowerShell SSH tunnels (separate terminals)
# ssh -L 9200:localhost:9200 zaheer@192.168.88.130
# ssh -L 5601:localhost:5601 zaheer@192.168.88.130
```

### Verify OpenSearch cluster health
```bash
curl -s http://localhost:9200/_cluster/health | python3 -m json.tool
```

**PASS:** `"status": "green"` or `"yellow"` (yellow = single-node, OK for dev)

### Verify logs are flowing from Fluent Bit
```bash
# Check index exists and document count
curl -s 'http://localhost:9200/_cat/indices/dr-platform-logs?v'

# Count documents
curl -s http://localhost:9200/dr-platform-logs/_count | python3 -m json.tool

# Sample the most recent log
curl -s 'http://localhost:9200/dr-platform-logs/_search?size=1&sort=@timestamp:desc' | \
  python3 -c "
import sys, json
hit = json.load(sys.stdin)['hits']['hits'][0]['_source']
print('Pod:', hit.get('kubernetes',{}).get('pod_name','?'))
print('Namespace:', hit.get('kubernetes',{}).get('namespace_name','?'))
print('Cluster:', hit.get('cluster_name','?'))
print('Log:', str(hit.get('log',''))[:100])
"
```

**PASS:**
- `dr-platform-logs` index exists with `docs.count > 0`
- Sample log shows `pod_name`, `namespace_name`, `cluster_name: dr-platform-primary-eks`

### Verify Fluent Bit pods are running
```bash
kubectl get pods -n logging --context primary
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --context primary --tail=5 2>&1 | grep -v "GET /health"
```

**PASS:** 2 Fluent Bit pods `Running`. No critical errors (CloudWatch IAM error is non-critical)

### OpenSearch Dashboards UI
```
http://localhost:5601
```
- Go to **Discover** → select `dr-platform-logs` index pattern
- Set time range to `Last 15 minutes`
- Logs from `dr-app`, `monitoring`, `logging` namespaces should appear

---

## TEST 12 — Velero Backup & Restore

### Verify BackupStorageLocation is available
```bash
KUBECONFIG=~/.kube/config velero backup-location get --kubecontext primary
```

**PASS:** `default` location shows `Phase: Available`

### List existing backups
```bash
KUBECONFIG=~/.kube/config velero backup get --kubecontext primary
```

**PASS:** Shows `test-backup-202604290624` with `STATUS: Completed`

### Run a new on-demand backup
```bash
KUBECONFIG=~/.kube/config velero backup create manual-backup-$(date +%Y%m%d%H%M) \
  --include-namespaces dr-app \
  --kubecontext primary \
  --wait
```

**PASS:** `Backup completed with status: Completed`

### Verify backup stored in S3
```bash
aws s3 ls s3://dr-platform-primary-velero-primary/velero/backups/ --region us-east-1
```

**PASS:** Lists backup directories with recent timestamps

### Verify backup schedule exists
```bash
KUBECONFIG=~/.kube/config velero schedule get --kubecontext primary
```

**PASS:** Shows `daily-cluster-backup` schedule (runs at 2am UTC, TTL 72h)

### Verify DR cluster Velero is also configured
```bash
KUBECONFIG=~/.kube/config velero backup-location get --kubecontext dr
```

**PASS:** `default` shows `Phase: Available`

---

## TEST 13 — IAM Roles (IRSA)

```bash
# Check all IRSA roles exist
aws iam list-roles --region us-east-1 \
  --query 'Roles[?contains(RoleName, `dr-platform`)].RoleName' \
  --output table
```

**PASS:** Should list ~8 roles: cluster, node, ebs-csi, velero (primary + dr), lb-controller, drift-detection, lambda, config

---

## TEST 14 — LIVE FAILOVER TEST (do this last — it changes state)

> **WARNING:** This promotes the RDS replica to a standalone primary, breaking replication.
> Run only when ready to demonstrate, and re-deploy DR Terraform after to restore.

### Step 1: Confirm both apps are healthy before starting
```bash
curl -s http://$PRIMARY_LB/health | python3 -c "import sys,json; d=json.load(sys.stdin); print('Primary:', d['status'])"
curl -s http://$DR_LB/health | python3 -c "import sys,json; d=json.load(sys.stdin); print('DR:', d['status'])"
```

### Step 2: Simulate primary failure by killing pods
```bash
kubectl scale deployment dr-status-monitor --replicas=0 -n dr-app --context primary
```

### Step 3: Watch Route53 detect the failure (30 seconds)
```bash
watch -n 10 "aws route53 get-health-check-status \
  --health-check-id $HC_ID \
  --query 'HealthCheckObservations[0].StatusReport.Status' --output text"
```

### Step 4: Watch CloudWatch alarm fire
```bash
watch -n 10 "aws cloudwatch describe-alarms \
  --alarm-names 'dr-platform-primary-primary-endpoint-down' \
  --region us-east-1 \
  --query 'MetricAlarms[0].StateValue' --output text"
```

### Step 5: Confirm Lambda was triggered
```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/dr-platform-primary-failover \
  --region us-east-1 \
  --start-time $(date -d '5 minutes ago' +%s000) \
  --query 'events[*].message' --output text
```

### Step 6: Confirm DR took over
```bash
# DR EKS should scale from 1 → 3 nodes
aws eks describe-nodegroup \
  --cluster-name dr-platform-dr-eks \
  --nodegroup-name dr-platform-dr-eks-workers \
  --region us-west-2 \
  --query 'nodegroup.scalingConfig' 2>&1

# DR RDS should now be a standalone primary (no replica source)
aws rds describe-db-instances \
  --db-instance-identifier dr-platform-dr-postgres-replica \
  --region us-west-2 \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' \
  --output table

# DR app should now show DB role = primary
curl -s http://$DR_LB/status | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('DR DB role after failover:', d['database']['role'])"
```

**PASS:**
- Lambda logs show failover triggered
- DR EKS: desiredSize changed to 3
- DR RDS: `ReadReplicaSourceDBInstanceIdentifier` is empty (promoted to primary)
- DR app: `database.role: primary`

### Step 7: Restore primary after demo
```bash
kubectl scale deployment dr-status-monitor --replicas=2 -n dr-app --context primary
```

---

## CHEAT SHEET — Key URLs & ARNs

```
Primary App:          http://a226966b5218e4a25ac3c61ccc08d58b-1999881320.us-east-1.elb.amazonaws.com
DR App:               http://a0540203aef364452b419e90298fab45-590619815.us-west-2.elb.amazonaws.com
Grafana (public):     http://a0b2fe304029b4e33a5f96c00d909abb-1112333123.us-east-1.elb.amazonaws.com
  Login:              admin / Admin@DR2024!
OpenSearch Dashboard: http://localhost:5601  (port-forward + SSH tunnel required)
OpenSearch API:       http://localhost:9200  (port-forward + SSH tunnel required)
Prometheus:           http://localhost:9090  (port-forward + SSH tunnel required)

Primary EKS:    dr-platform-primary-eks (us-east-1)
DR EKS:         dr-platform-dr-eks (us-west-2)
Primary RDS:    dr-platform-primary-postgres.cc12muyqmzlc.us-east-1.rds.amazonaws.com
DR RDS:         dr-platform-dr-postgres-replica.c5wswi8ey630.us-west-2.rds.amazonaws.com
ECR:            380093117517.dkr.ecr.us-east-1.amazonaws.com/dr-platform/dr-status-monitor
Lambda:         dr-platform-primary-failover (us-east-1)
SNS Topic:      arn:aws:sns:us-east-1:380093117517:dr-platform-primary-dr-alerts
HC ID:          d7a6a372-a27e-496d-86b6-f6fe7a10de0b
S3 Primary:     dr-platform-primary-velero-primary (us-east-1)
S3 DR:          dr-platform-primary-velero-dr (us-west-2)
```

---

## PORT-FORWARD CHEAT SHEET

Run on VM first, then open SSH tunnels from Windows PowerShell:

```bash
# VM — start all port-forwards at once
kubectl port-forward svc/opensearch-cluster-master -n logging 9200:9200 --context primary &
kubectl port-forward svc/opensearch-dashboards -n logging 5601:5601 --context primary &
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 --context primary &

# Windows PowerShell — SSH tunnels (one per terminal)
ssh -L 9200:localhost:9200 zaheer@192.168.88.130
ssh -L 5601:localhost:5601 zaheer@192.168.88.130
ssh -L 9090:localhost:9090 zaheer@192.168.88.130
```
