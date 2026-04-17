#!/bin/bash
# ============================================================
# deploy-primary.sh — Deploy DR Platform PRIMARY region (us-east-1)
# Usage: ./scripts/deploy-primary.sh
# Prerequisites: AWS CLI configured, Terraform installed, kubectl installed
# ============================================================
set -euo pipefail

PRIMARY_REGION="us-east-1"
DR_REGION="us-west-2"
PROJECT="dr-platform"
TFSTATE_BUCKET="${PROJECT}-tfstate-primary"
LOCK_TABLE="${PROJECT}-tfstate-lock"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=============================================="
echo " DR Platform — PRIMARY Region Deployment"
echo "  Region:    $PRIMARY_REGION"
echo "  Account:   $ACCOUNT_ID"
echo "  Project:   $PROJECT"
echo "=============================================="

# ── Step 1: Bootstrap Terraform remote state ──────────────
echo ""
echo "[1/6] Setting up Terraform remote state..."

aws s3api create-bucket \
  --bucket "$TFSTATE_BUCKET" \
  --region "$PRIMARY_REGION" 2>/dev/null || echo "  Bucket already exists"

aws s3api put-bucket-versioning \
  --bucket "$TFSTATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$TFSTATE_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table \
  --table-name "$LOCK_TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$PRIMARY_REGION" 2>/dev/null || echo "  DynamoDB table already exists"

echo "  Remote state configured"

# ── Step 2: Create DR region S3 bucket for cross-region ──
echo ""
echo "[2/6] Creating DR region Velero bucket..."
aws s3api create-bucket \
  --bucket "${PROJECT}-dr-velero" \
  --region "$DR_REGION" \
  --create-bucket-configuration LocationConstraint="$DR_REGION" 2>/dev/null || echo "  DR bucket already exists"
aws s3api put-bucket-versioning --bucket "${PROJECT}-dr-velero" --versioning-configuration Status=Enabled

# ── Step 3: Terraform init + plan ─────────────────────────
echo ""
echo "[3/6] Initializing Terraform..."
cd terraform/primary
terraform init -upgrade -input=false

echo ""
echo "[4/6] Validating and planning..."
terraform validate
terraform plan \
  -var="aws_account_id=$ACCOUNT_ID" \
  -var="hosted_zone_id=${HOSTED_ZONE_ID:-PLACEHOLDER}" \
  -var="domain_name=${DOMAIN_NAME:-app.example.com}" \
  -var="alert_emails=[\"${ALERT_EMAIL:-admin@example.com}\"]" \
  -var="jenkins_ip=${JENKINS_IP:-0.0.0.0}" \
  -out=primary.tfplan

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Review the plan above, then press ENTER to deploy"
echo "  Ctrl+C to cancel"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r

# ── Step 5: Apply ─────────────────────────────────────────
echo ""
echo "[5/6] Deploying infrastructure (~15 minutes)..."
terraform apply primary.tfplan

# ── Step 6: Configure kubectl + install K8s tools ─────────
echo ""
echo "[6/6] Configuring kubectl and deploying K8s tools..."
EKS_CLUSTER=$(terraform output -raw eks_cluster_name)
aws eks update-kubeconfig --region "$PRIMARY_REGION" --name "$EKS_CLUSTER"

echo "  Installing K8s tools via Ansible..."
cd ../../
ansible-playbook \
  -i ansible/inventory/hosts.yaml \
  ansible/playbooks/deploy-k8s-tools.yaml \
  -e "cluster_name=$EKS_CLUSTER" \
  -e "region=$PRIMARY_REGION" \
  -e "velero_bucket=${PROJECT}-primary-velero-primary" \
  -e "velero_role_arn=$(cd terraform/primary && terraform output -raw velero_iam_role_arn)" \
  -e "lb_controller_role_arn=$(cd terraform/primary && terraform output -raw lb_controller_role_arn)" \
  -e "drift_detection_role_arn=$(cd terraform/primary && terraform output -raw drift_detection_role_arn)" \
  -e "sns_topic_arn=$(cd terraform/primary && terraform output -raw sns_topic_arn)" \
  -e "opensearch_password=${OPENSEARCH_PASSWORD:-Admin@DR2024!}" \
  -e "groq_api_key=${GROQ_API_KEY:-}"
  # GROQ_API_KEY: free from https://console.groq.com (optional — AI falls back to Ollama if not set)

echo ""
echo "=============================================="
echo "  PRIMARY deployment complete!"
echo "=============================================="
cd terraform/primary && terraform output
