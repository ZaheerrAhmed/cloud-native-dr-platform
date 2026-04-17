<div align="center">

# Phoenix DR Platform

### *A Cloud-Native Disaster Recovery System That Heals Itself*

[![AWS](https://img.shields.io/badge/AWS-Multi--Region-FF9900?style=flat&logo=amazonaws)](https://aws.amazon.com)
[![Terraform](https://img.shields.io/badge/Terraform-1.9-7B42BC?style=flat&logo=terraform)](https://terraform.io)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.30-326CE5?style=flat&logo=kubernetes)](https://kubernetes.io)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?style=flat&logo=argo)](https://argoproj.github.io)
[![License](https://img.shields.io/badge/Standard-ISO%2022301-blue)](https://www.iso.org/standard/75106.html)

**RTO < 5 minutes &nbsp;|&nbsp; RPO < 1 minute &nbsp;|&nbsp; Zero human intervention required**

</div>

---

## The Problem This Solves

Most disaster recovery plans are PDF documents that live in a SharePoint folder nobody opens.

When a region goes down at 2 AM, those documents require an engineer to wake up, read the runbook, SSH into servers, run commands in the right order, update DNS, restart services, and pray nothing was missed. That process takes hours. In 2025, the AWS us-east-1 outage cost businesses an estimated **$581 million** — not because the problem was hard to fix, but because humans are slow.

This platform replaces the runbook with code. When the primary region fails:

1. Route 53 detects it in **30 seconds**
2. EventBridge routes the event to a Lambda function
3. Lambda promotes the RDS read replica to a standalone primary in us-west-2
4. Lambda scales the standby EKS cluster from 1 node to 3
5. Route 53 DNS flips automatically — no human clicks DNS, it's health-check-based
6. ArgoCD ensures the DR cluster is already running the latest code, always

Total elapsed time from failure to traffic-on-DR: **under 5 minutes**. Total engineer intervention required: **zero**.

---

## Architecture

```
 Developer
     │
     │  git push
     ▼
 Jenkins CI  ──►  Docker Build  ──►  Push to ECR  ──►  Git commit (image tag)
                                                              │
                                                    ArgoCD detects change
                                                              │
                              ┌───────────────────────────────┘
                              │
              ┌───────────────┴────────────────┐
              │                                │
              ▼                                ▼
 ┌────────────────────────┐      ┌────────────────────────────┐
 │   us-east-1  PRIMARY   │      │   us-west-2   DR STANDBY   │
 │────────────────────────│      │────────────────────────────│
 │  EKS 1.30  (2-4 nodes) │      │  EKS 1.30  (1→3 on fail)   │
 │  ├ dr-status-monitor   │      │  ├ dr-status-monitor       │
 │  ├ Prometheus+Grafana  │      │  ├ Prometheus + Grafana    │
 │  ├ OpenSearch+FluentBit│      │  ├ OpenSearch + Fluent Bit │
 │  ├ Velero (hourly)     │      │  └ Velero (CRR replica)    │
 │  ├ ArgoCD              │      │                            │
 │  ├ OPA Gatekeeper      │ WAL  │  RDS PostgreSQL 16         │
 │  └ Drift Detection     │─────►│  Read Replica              │
 │                        │      │  (promoted on failover)    │
 │  RDS PostgreSQL 16     │ CRR  │                            │
 │  Multi-AZ primary      │─────►│  S3 Velero Bucket          │
 │  S3 Velero Bucket      │      │  (receives replicas)       │
 └────────────────────────┘      └────────────────────────────┘
              │
              │  Route 53 polls /health every 10 seconds
              │  3 failures → CloudWatch ALARM
              │              → EventBridge
              │              → Lambda fires:
              │                  1. promote RDS read replica
              │                  2. scale EKS  1 → 3 nodes
              │                  3. send SNS alert
              │
              └──► Route 53 DNS flips to DR automatically
```

**Automated failover chain:**
```
Route53 health check fails (30s)
  → CloudWatch alarm (ALARM state)
    → EventBridge pattern match
      → Lambda: rds.promote_read_replica()
      → Lambda: eks.update_nodegroup_config(desiredSize=3)
      → Lambda: sns.publish()  ← email alert to operator
        → Route53 DNS flips to DR ALB  ← automatic, health-check-based
          → Traffic served from us-west-2
```

---

## Technology Stack

| Layer | Technology | Why This Choice |
|-------|-----------|----------------|
| Infrastructure | **Terraform 1.9** (modular) | Reproducible, reviewable, versioned infrastructure |
| Container Platform | **AWS EKS 1.30** | Managed K8s — no control plane to babysit; IRSA for pod-level IAM |
| Database | **RDS PostgreSQL 16** | Multi-AZ + cross-region replica; managed backups; WAL replication lag < 1s |
| Backup | **Velero 1.14** + S3 CRR | K8s-native backup; CRR ensures DR region has copies before disaster |
| GitOps | **ArgoCD 2.11** | Both clusters always in sync; selfHeal reverts manual drift; full audit trail |
| CI/CD | **Jenkins** (Groovy pipeline) | Build → test → ECR → Git commit → ArgoCD sync; ArgoCD-safe (no `kubectl set image`) |
| Monitoring | **Prometheus + Grafana** | kube-prometheus-stack; /metrics auto-scraped from app; AlertManager ready |
| Logging / SIEM | **OpenSearch + Fluent Bit** | Centralized logs across both clusters; EKS control plane logs included |
| Policy | **OPA Gatekeeper** | Admission control: resource limits + liveness probes enforced at API server |
| Drift Detection | **driftctl + Groq AI** | Every 6h: scan IaC drift → Groq llama3-70b analyses risk → Slack + SNS alert |
| Secrets | **AWS Secrets Manager** | DB password auto-generated by Terraform; never in Git, logs, or env files |
| Image Registry | **AWS ECR** | Lifecycle policies; vulnerability scan on push; ECR replication to DR region |
| Failover Orchestrator | **AWS Lambda** (Python 3.12) | Event-driven; sub-30s execution; no servers to maintain |
| DNS Failover | **Route 53** health checks | Health-check-based automatic DNS flip; no API call needed to switch traffic |
| Automation | **Ansible** | Idempotent tool install + K8s secrets injection |

---

## Key Design Decisions

**Why not just use RDS Multi-AZ for DR?**
Multi-AZ protects against AZ failure within a region. A full regional outage (like us-east-1 going dark) takes everything down. You need a separate region with an independent RDS instance. Multi-AZ is the primary's resilience within us-east-1; the read replica in us-west-2 is the cross-region DR.

**Why does the DR EKS cluster run 1 node at standby?**
Running 3 nodes × 24/7 in both regions doubles the compute cost for zero benefit during normal operation. The Lambda failover handler scales from 1 → 3 in ~3 minutes. That's an acceptable trade-off: save ~60% on standby costs, accept 3 extra minutes of EKS capacity ramp-up during failover.

**Why commit image tags to Git instead of `kubectl set image`?**
ArgoCD has `selfHeal: true` — it continuously reconciles cluster state to match Git. If Jenkins uses `kubectl set image`, ArgoCD immediately reverts it (Git still has `REPLACE_WITH_ECR_URL`). The only correct way to update a workload under ArgoCD is to update Git. Jenkins commits the new image tag; ArgoCD detects the commit and deploys it. Full audit trail, no drift.

**Why Groq API instead of self-hosted Ollama?**
Ollama requires 3–4 GB of additional RAM per node to run llama3.2 locally. At `t3.large` node size, this would exhaust memory and cause OOM kills of other workloads. Groq's free tier (14,400 requests/day on llama3-70b-8192) is more capable and costs nothing. Ollama remains as a fallback if the Groq key is not set.

**Why OPA Gatekeeper in `warn` mode?**
In a new cluster, switching directly to `deny` mode would block any deployment that doesn't meet the policy — including Helm charts from third parties. Starting in `warn` mode lets operators see violations without breakage, then graduate to `deny` once all charts are compliant. This is production practice, not a shortcut.

---

## Repository Structure

```
phoenix-dr-platform/
├── terraform/
│   ├── primary/               # us-east-1 — VPC, EKS, RDS, S3, Lambda, Route53, ECR, Config
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── variables.tf
│   │   ├── backend.tf         # S3 remote state
│   │   ├── provider.tf        # aws + aws.dr alias
│   │   └── terraform.tfvars.example
│   ├── dr/                    # us-west-2 — VPC, EKS (standby), RDS replica, S3
│   └── modules/               # vpc · eks · rds · s3 · route53
├── kubernetes/
│   ├── app/                   # Deployment, Service, HPA, ServiceAccount
│   ├── argocd/                # App-of-Apps (watches this directory only)
│   ├── monitoring/            # kube-prometheus-stack Helm values
│   ├── logging/               # OpenSearch + Fluent Bit Helm values
│   ├── velero/                # Backup schedules (hourly + daily)
│   ├── opa-gatekeeper/        # ISO 22301 admission constraints (ConstraintTemplate + Constraint)
│   └── drift-detection/       # driftctl CronJob + AI Analyzer Deployment + shared PVC
├── lambda/
│   └── failover_handler.py    # RDS promote + EKS scale-up + SNS alert
├── docker/
│   └── app/                   # Flask app, Dockerfile (multi-stage), requirements.txt
├── jenkins/
│   └── Jenkinsfile            # 7-stage pipeline: test → SonarQube → build → ECR → GitOps deploy
├── ansible/
│   ├── inventory/hosts.yaml   # local connection (runs on Ubuntu VM)
│   └── playbooks/
│       ├── install-tools.yaml       # kubectl, Helm, Terraform, Velero, ArgoCD, driftctl
│       ├── deploy-k8s-tools.yaml    # Helm charts + K8s secrets injection
│       └── drift-remediation.yaml   # Groq AI drift analysis via Ansible
└── scripts/
    ├── deploy-primary.sh      # End-to-end primary region deployment
    └── deploy-dr.sh           # End-to-end DR region deployment
```

---

## Deploy

```bash
# Prerequisites (install once — handled by ansible/playbooks/install-tools.yaml)
# AWS CLI, Terraform >= 1.6, kubectl, Helm, Ansible, Velero CLI, ArgoCD CLI, driftctl
# See: ansible/playbooks/install-tools.yaml

# Store secrets in AWS Secrets Manager (one-time)
aws secretsmanager create-secret --region us-east-1 \
  --name "dr-platform/groq-api-key" \
  --secret-string "gsk_YOUR_KEY"    # free key: https://console.groq.com

# Export required variables
export ALERT_EMAIL="your@email.com"
export GROQ_API_KEY=$(aws secretsmanager get-secret-value \
  --region us-east-1 --secret-id "dr-platform/groq-api-key" \
  --query SecretString --output text)

# Deploy primary region (us-east-1) — ~20 minutes
./scripts/deploy-primary.sh

# Deploy DR standby (us-west-2) — ~15 minutes (run after primary completes)
./scripts/deploy-dr.sh
```

What these scripts do automatically:
1. Bootstrap Terraform remote state (S3 + DynamoDB)
2. `terraform apply` — VPC, EKS, RDS, S3, Lambda, Route53, ECR, IAM, AWS Config
3. `aws eks update-kubeconfig` — configure kubectl
4. `ansible-playbook deploy-k8s-tools.yaml` — install all Helm charts, inject K8s secrets
5. Application deployed via ArgoCD from this Git repository

---

## How Secrets Flow (Zero Plaintext Anywhere)

```
Terraform random_password (24 chars)
         │
         ▼
AWS Secrets Manager  ←─── never written to disk, never in Git
         │
         ▼ (at deploy time, Ansible fetches it)
kubectl create secret generic db-credentials
         │
         ▼ (Kubernetes injects as env var)
Pod: DB_PASSWORD=<value>   ←── no_log: true in Ansible, never in logs
```

Every credential follows the same pattern. The only credential that touches the VM directly is the AWS CLI key, which lives in `~/.aws/credentials` and is never committed.

---

## CI/CD Pipeline

```
git push origin main
      │
      ▼
Jenkins (7 stages)
  ├── Checkout
  ├── Unit Tests          (pytest + coverage → Cobertura report)
  ├── SonarQube Analysis  (code quality gate)
  ├── Docker Build        (multi-stage, non-root user, port 8080)
  ├── Push to ECR         (tagged + latest; vulnerability scan on push)
  ├── Terraform Validate  (plan-only — IaC sanity check on main branch)
  └── Deploy
        ├── Update image tag in kubernetes/app/deployment.yaml
        ├── git commit + push  (ArgoCD-safe — never kubectl set image)
        ├── argocd app sync (primary)
        └── argocd app sync (DR cluster)
```

ArgoCD's `selfHeal: true` means the cluster is always the authoritative reflection of Git. Any out-of-band change is automatically reverted. This makes every deployment auditable and every rollback a `git revert`.

---

## Observability

| Signal | Tool | What It Covers |
|--------|------|---------------|
| Metrics | Prometheus + Grafana | CPU, memory, request rate, error rate, DB connection pool |
| Logs | Fluent Bit → OpenSearch | Application logs, EKS control-plane logs, Lambda logs |
| Traces | (future: OpenTelemetry) | — |
| Alerts | AlertManager + SNS + Slack | Failover events, HIGH/CRITICAL drift, health check failures |
| Drift | driftctl + Groq AI | IaC vs live-state gap detection every 6 hours |
| Compliance | AWS Config | Continuous resource configuration recording |
| Audit | CloudWatch + OpenSearch | All API calls, pod lifecycle, failover events |

---

## Compliance Alignment

| Control | Implementation |
|---------|---------------|
| ISO 22301 §8.4 — Business impact analysis | RTO/RPO targets defined and tested via health check automation |
| ISO 22301 §8.5 — Business continuity strategy | Active-standby architecture with automated promotion |
| NIST SP 800-34 §3.4 — Alternate site | us-west-2 DR region, independent VPC, independent RDS |
| NIST SP 800-34 §3.5 — Data backup | Velero hourly backups + RDS automated 7-day backups + S3 CRR |
| OPA Gatekeeper | All Deployments must have resource limits + liveness probes |
| IMDSv2 required | SSRF protection on all EKS node launch templates |
| Encryption at rest | EBS gp3 volumes encrypted; RDS storage encrypted; S3 SSE-AES256 |
| Secrets management | AWS Secrets Manager; zero plaintext credentials in code or logs |

---

## Author

**Zaheer Ahmed**
Cloud & DevOps Engineer — EduQual Level 6
Al-Nafi International College
