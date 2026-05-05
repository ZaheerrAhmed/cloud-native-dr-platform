# Orchestrating Cloud-Native Disaster Recovery Platform

**with Automated Failover, Data Replication, and Business Continuity for Critical Systems**

**Zaheer Ahmad** — Diploma in Artificial Intelligence Operations (EduQual Level 6)
Al-Nafi International College

---

## Overview

This project implements a production-grade cloud-native disaster recovery platform on AWS. The platform automatically detects primary region failure and switches traffic to a standby DR region without any human intervention. It combines Infrastructure as Code, GitOps, AI-powered security monitoring, and automated backup to achieve business continuity for critical systems.

**Primary Region:** AWS us-east-1
**DR Region:** AWS us-west-2
**RTO Target:** 15 minutes
**RPO Target:** 5 minutes

---

## Architecture

```
Developer
    │
    │  git push
    ▼
GitHub Repository
    │
    ├── ArgoCD (GitOps sync to both clusters)
    └── Terraform (infrastructure provisioning)

┌─────────────────────────┐         ┌─────────────────────────┐
│   us-east-1  PRIMARY    │         │   us-west-2   DR        │
│─────────────────────────│         │─────────────────────────│
│  EKS Cluster (2 nodes)  │         │  EKS Cluster (1→3 nodes)│
│  dr-status-monitor      │         │  dr-status-monitor      │
│  Prometheus + Grafana   │         │  Prometheus + Grafana   │
│  OpenSearch + FluentBit │         │  Velero                 │
│  Velero                 │  WAL    │                         │
│  ArgoCD                 │────────►│  RDS PostgreSQL 16      │
│  OPA Gatekeeper         │  repl.  │  Read Replica           │
│  AI Anomaly Detector    │         │  (promoted on failover) │
│  AI Drift Analyzer      │  S3     │                         │
│                         │  CRR   ►│  S3 Velero Bucket       │
│  RDS PostgreSQL 16      │         │  (replicated backups)   │
│  S3 Velero Bucket       │         │                         │
└─────────────────────────┘         └─────────────────────────┘
            │
            │  Route53 health check every 20 seconds
            │  3 failures → CloudWatch Alarm
            │            → EventBridge Rule
            │            → Lambda Function:
            │                1. Promote RDS read replica
            │                2. Scale EKS 1 → 3 nodes
            │                3. Send SNS alert
            │
            └──► Route53 DNS switches to DR automatically
```

---

## What Was Built

### Infrastructure (Terraform)
- Two VPCs across us-east-1 and us-west-2 with public and private subnets
- Two EKS clusters (Kubernetes 1.30) with managed node groups
- RDS PostgreSQL 16 primary with cross-region read replica
- S3 buckets with cross-region replication for Velero backups
- Lambda function for automated failover orchestration
- Route53 health checks with automatic DNS failover
- 18 IAM roles using IRSA (IAM Roles for Service Accounts)
- DynamoDB table for Terraform state locking
- AWS Config for resource configuration recording

### Kubernetes Platform
- **ArgoCD** — app-of-apps GitOps pattern syncing all components from GitHub
- **OPA Gatekeeper** — admission controller enforcing ISO 22301 policies
- **Prometheus + Grafana** — 7 dashboards, 149 alert rules
- **OpenSearch + Fluent Bit** — centralised SIEM with 113,000+ log entries
- **Velero** — daily automated backups with 72-hour retention

### AI Components
- **AI Anomaly Detector** — Kubernetes CronJob running every 5 minutes. Queries OpenSearch for security-relevant logs and sends them to Groq llama-3.3-70b-versatile for threat analysis. Fires SNS alert for MEDIUM and above threats. Results indexed to OpenSearch security-analysis index.
- **AI Drift Analyzer** — Always-running Deployment. Reads driftctl infrastructure scan reports every 6 hours and sends to Groq AI for risk assessment. Returns risk level, affected resources, remediation steps, and ISO 22301 compliance impact.
- **driftctl CronJob** — Compares live AWS infrastructure against Terraform state every 6 hours.

### Automated Failover Chain
1. Route53 health check detects primary failure in ~60 seconds
2. CloudWatch alarm fires
3. EventBridge triggers Lambda
4. Lambda promotes RDS read replica to standalone primary (~5-8 minutes)
5. Lambda scales DR EKS nodegroup from 1 to 3 nodes
6. Route53 DNS switches to DR load balancer
7. SNS email alert sent to operator

---

## Technology Stack

| Component | Technology |
|---|---|
| Infrastructure as Code | Terraform 1.9 with reusable modules |
| Container Orchestration | AWS EKS 1.30 |
| Database | RDS PostgreSQL 16 with cross-region replica |
| Backup | Velero 1.14 + S3 Cross-Region Replication |
| GitOps | ArgoCD with app-of-apps pattern |
| Monitoring | Prometheus + Grafana (kube-prometheus-stack) |
| Logging / SIEM | OpenSearch + Fluent Bit |
| Policy Enforcement | OPA Gatekeeper |
| Drift Detection | driftctl + Groq llama-3.3-70b-versatile |
| AI Threat Detection | Groq llama-3.3-70b-versatile |
| Failover Orchestration | AWS Lambda (Python 3.12) |
| DNS Failover | Route53 health-check-based routing |
| Alerts | AWS SNS |
| Container Registry | AWS ECR |

---

## Compliance

| Standard | Implementation |
|---|---|
| ISO 22301 §8.4 — Business Impact Analysis | RTO/RPO targets defined and validated through automated health checks |
| ISO 22301 §8.5 — Business Continuity Strategy | Active/Passive multi-region architecture with automated promotion |
| NIST SP 800-34 §3.4 — Alternate Site | Independent us-west-2 DR region with separate VPC and RDS instance |
| NIST SP 800-34 §3.5 — Data Backup | Velero daily backups + RDS automated backups + S3 CRR |
| OPA Gatekeeper | All Deployments must have memory limits and liveness probes |
| Encryption at rest | EBS volumes encrypted, RDS storage encrypted, S3 SSE-AES256 |
| Secrets management | IRSA for pod-level IAM, no hardcoded credentials anywhere |
| Audit trail | OpenSearch logs, AWS CloudTrail, ArgoCD audit log |

---

## Repository Structure

```
cloud-native-dr-platform/
├── terraform/
│   ├── primary/          # us-east-1 infrastructure
│   ├── dr/               # us-west-2 infrastructure
│   └── modules/          # vpc, eks, rds, s3, route53
├── kubernetes/
│   ├── app/              # dr-status-monitor application
│   ├── argocd/           # app-of-apps GitOps configuration
│   ├── monitoring/       # Prometheus and Grafana values
│   ├── logging/          # OpenSearch and Fluent Bit values
│   ├── velero/           # Backup schedules
│   ├── opa-gatekeeper/   # ISO 22301 admission policies
│   ├── ai-detection/     # AI anomaly detector CronJob
│   └── drift-detection/  # driftctl + AI analyzer
├── lambda/
│   └── failover_handler.py
├── docker/
│   └── app/              # Flask application and Dockerfile
├── ansible/
│   └── playbooks/        # Tool installation and deployment
└── docs/
    └── architecture.svg  # Architecture diagram
```

---

## Deployment

```bash
# 1. Clone the repository
git clone https://github.com/ZaheerrAhmed/cloud-native-dr-platform.git
cd cloud-native-dr-platform

# 2. Configure AWS credentials
aws configure

# 3. Deploy primary region (us-east-1)
cd terraform/primary
terraform init
terraform apply

# 4. Deploy DR region (us-west-2)
cd ../dr
terraform init
terraform apply

# 5. Install Kubernetes tools via Ansible
cd ../../ansible
ansible-playbook playbooks/install-tools.yaml
ansible-playbook playbooks/deploy-k8s-tools.yaml
```

---

## Real World Relevance

In October 2025, AWS us-east-1 suffered a 15-hour DNS outage affecting 2,500+ companies including Netflix, Reddit, and McDonald's with $581 million in insurance losses. This platform addresses exactly that scenario — automated cross-region failover that detects failure within 60 seconds and completes recovery in 15 minutes with zero human intervention.

---

**Author:** Zaheer Ahmad
**Programme:** Diploma in Artificial Intelligence Operations — EduQual Level 6
**Institution:** Al-Nafi International College
