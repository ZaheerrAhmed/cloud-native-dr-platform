# Pre-Exam Checklist — Phoenix DR Platform

> Run through this top to bottom before the exam.
> Today's session covers Step 1 (Primary Terraform). Everything else needs to be done fresh.

---

## STEP 1 — Primary Region Infrastructure (us-east-1) ✅ DONE IN THIS SESSION
- [x] AWS credentials configured
- [x] S3 state buckets created (dr-platform-tfstate-primary, dr-platform-tfstate-dr)
- [x] DynamoDB lock tables created (both regions)
- [x] terraform.tfvars filled in (primary)
- [x] HCL syntax fixes applied to all modules
- [x] terraform init + validate + plan (primary)
- [x] terraform apply (primary) — VPC, EKS, RDS, S3, ECR, Lambda, Route53, IAM

---

## STEP 2 — DR Region Infrastructure (us-west-2) ❌ NOT DONE

```bash
# Get outputs from primary first
cd terraform/primary
terraform output

# Fill in DR tfvars using those outputs
cp terraform/dr/terraform.tfvars.example terraform/dr/terraform.tfvars
# Edit terraform/dr/terraform.tfvars:
#   aws_account_id            = "380093117517"
#   primary_db_arn            = <from: terraform output rds_primary_arn>
#   primary_velero_bucket_arn = <from: terraform output velero_bucket_arn>

cd terraform/dr
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

---

## STEP 3 — Connect kubectl to Both Clusters ❌ NOT DONE

```bash
# Primary cluster
aws eks update-kubeconfig \
  --region us-east-1 \
  --name dr-platform-primary-eks \
  --alias primary

# DR cluster
aws eks update-kubeconfig \
  --region us-west-2 \
  --name dr-platform-dr-eks \
  --alias dr

# Verify both
kubectl get nodes --context primary
kubectl get nodes --context dr
```

---

## STEP 4 — Build & Push Docker Image to ECR ❌ NOT DONE

```bash
# Get ECR URL
ECR_URL=$(aws ecr describe-repositories \
  --repository-names dr-platform/dr-status-monitor \
  --region us-east-1 \
  --query 'repositories[0].repositoryUri' \
  --output text)

# Login
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin $ECR_URL

# Build and push
cd docker
docker build -t $ECR_URL:latest ./app
docker push $ECR_URL:latest
```

---

## STEP 5 — Install Helm + Deploy Core Kubernetes Tools ❌ NOT DONE

Install Helm if not present:
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 5a. ArgoCD (primary cluster)
```bash
kubectl --context primary create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd \
  --context primary \
  --wait
# Get ArgoCD admin password
kubectl --context primary -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### 5b. Prometheus + Grafana (both clusters)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Primary
kubectl --context primary create namespace monitoring
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --context primary \
  -f kubernetes/monitoring/kube-prometheus-stack-values.yaml \
  --wait

# DR
kubectl --context dr create namespace monitoring
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --context dr \
  -f kubernetes/monitoring/kube-prometheus-stack-values.yaml \
  --wait
```

### 5c. OpenSearch + Fluent Bit (both clusters)
```bash
helm repo add opensearch https://opensearch-project.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# Primary
kubectl --context primary create namespace logging
helm install opensearch opensearch/opensearch \
  --namespace logging --context primary \
  -f kubernetes/logging/opensearch-values.yaml --wait
helm install fluent-bit fluent/fluent-bit \
  --namespace logging --context primary \
  -f kubernetes/logging/fluent-bit-values.yaml

# DR (same commands with --context dr)
```

### 5d. Velero (both clusters)
```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts

# Get bucket names from Terraform outputs
PRIMARY_BUCKET=$(cd terraform/primary && terraform output -raw velero_bucket_name)
DR_BUCKET="dr-platform-primary-velero-dr"
VELERO_ROLE_ARN=$(cd terraform/primary && terraform output -raw velero_iam_role_arn)

# Primary
kubectl --context primary create namespace velero
helm install velero vmware-tanzu/velero \
  --namespace velero --context primary \
  -f kubernetes/velero/velero-values.yaml \
  --set configuration.backupStorageLocation[0].bucket=$PRIMARY_BUCKET \
  --set serviceAccount.server.annotations."eks\.amazonaws\.com/role-arn"=$VELERO_ROLE_ARN

# Apply backup schedule
kubectl --context primary apply -f kubernetes/velero/backup-schedule.yaml
```

### 5e. OPA Gatekeeper (primary)
```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace \
  --context primary \
  --wait
kubectl --context primary apply -f kubernetes/opa-gatekeeper/dr-constraints.yaml
```

### 5f. AWS Load Balancer Controller (both clusters)
```bash
helm repo add eks https://aws.github.io/eks-charts

# Primary
LB_ROLE_ARN=$(cd terraform/primary && terraform output -raw lb_controller_iam_role_arn)
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system --context primary \
  --set clusterName=dr-platform-primary-eks \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$LB_ROLE_ARN

# DR (get DR LB role ARN from DR terraform output)
```

---

## STEP 6 — Deploy Application ❌ NOT DONE

```bash
# Update image in deployment.yaml with your ECR URL first
ECR_URL=$(aws ecr describe-repositories \
  --repository-names dr-platform/dr-status-monitor \
  --region us-east-1 \
  --query 'repositories[0].repositoryUri' --output text)

sed -i "s|IMAGE_PLACEHOLDER|$ECR_URL:latest|g" \
  kubernetes/app/deployment.yaml

kubectl --context primary apply -f kubernetes/app/namespace.yaml
kubectl --context primary apply -f kubernetes/app/deployment.yaml
kubectl --context primary apply -f kubernetes/app/service.yaml

# Same for DR cluster
kubectl --context dr apply -f kubernetes/app/namespace.yaml
kubectl --context dr apply -f kubernetes/app/deployment.yaml
kubectl --context dr apply -f kubernetes/app/service.yaml
```

---

## STEP 7 — ArgoCD App of Apps ❌ NOT DONE

```bash
# Point ArgoCD at this Git repo
kubectl --context primary apply -f kubernetes/argocd/app-of-apps.yaml
```

---

## STEP 8 — Drift Detection ❌ NOT DONE

```bash
kubectl --context primary create namespace drift-detection
kubectl --context primary apply -f kubernetes/drift-detection/driftctl-cronjob.yaml
kubectl --context primary apply -f kubernetes/drift-detection/ollama-deployment.yaml
kubectl --context primary apply -f kubernetes/drift-detection/ai-analyzer-deployment.yaml
```

---

## STEP 9 — Update Route53 ALB DNS Values ❌ NOT DONE

After ALB controller creates ingress ALBs, get their DNS names and update Terraform:

```bash
# Get ALB DNS from primary cluster
PRIMARY_ALB=$(kubectl --context primary get ingress -A \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

DR_ALB=$(kubectl --context dr get ingress -A \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

# Update terraform/primary/main.tf with real ALB values, then re-apply
# primary_alb_dns = "$PRIMARY_ALB"
# dr_alb_dns      = "$DR_ALB"
cd terraform/primary && terraform apply
```

---

## STEP 10 — Confirm SNS Email Subscription ❌ NOT DONE

- Check inbox for **crownsole1512@gmail.com**
- Click the "Confirm subscription" link from AWS SNS
- Without this, failover alerts won't be delivered

---

## STEP 11 — Test Failover ❌ NOT DONE

```bash
chmod +x scripts/test-failover.sh
./scripts/test-failover.sh
```

Watch:
1. Route53 health check fails after 3 consecutive failures
2. CloudWatch alarm triggers → EventBridge → Lambda fires
3. Lambda promotes RDS read replica → scales DR EKS to 3 nodes
4. DNS flips to DR ALB
5. SNS alert arrives in email

---

## QUICK REFERENCE — Useful Commands

```bash
# Check what's running
kubectl --context primary get pods -A
kubectl --context dr get pods -A

# Get Grafana URL
kubectl --context primary -n monitoring get svc kube-prometheus-stack-grafana

# Get ArgoCD URL
kubectl --context primary -n argocd get svc argocd-server

# Terraform outputs (primary)
cd terraform/primary && terraform output

# Check AWS resources
aws eks list-clusters --region us-east-1
aws rds describe-db-instances --region us-east-1 --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus]'
```

---

## COST REMINDER
- Budget: $200 credit
- Estimated total (7.5 days, both regions): ~$114
- Buffer: ~$86
- **Teardown after exam:** `terraform destroy` in both dr/ and primary/ directories
