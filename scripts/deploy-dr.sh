#!/bin/bash
# ============================================================
# deploy-dr.sh — Deploy DR Platform DR region (us-west-2)
# Usage: ./scripts/deploy-dr.sh
# Run AFTER deploy-primary.sh completes (needs PRIMARY_DB_ARN)
# ============================================================
set -euo pipefail

DR_REGION="us-west-2"
PRIMARY_REGION="us-east-1"
PROJECT="dr-platform"
TFSTATE_BUCKET="${PROJECT}-tfstate-dr"
LOCK_TABLE="${PROJECT}-tfstate-lock"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=============================================="
echo " DR Platform — DR Region Deployment"
echo "  Region:    $DR_REGION"
echo "  Account:   $ACCOUNT_ID"
echo "  Project:   $PROJECT"
echo "=============================================="

# ── Step 1: Get Primary RDS ARN (needed for read replica) ──
echo ""
echo "[1/6] Fetching primary RDS ARN..."
cd terraform/primary
PRIMARY_DB_ARN=$(terraform output -raw rds_primary_arn 2>/dev/null || \
  aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --query "DBInstances[?DBInstanceIdentifier=='${PROJECT}-primary-postgres'].DBInstanceArn" \
    --output text)
cd ../../

if [ -z "$PRIMARY_DB_ARN" ] || [ "$PRIMARY_DB_ARN" = "None" ]; then
  echo "ERROR: Could not determine primary RDS ARN."
  echo "  Make sure deploy-primary.sh has been run first."
  exit 1
fi
echo "  Primary DB ARN: $PRIMARY_DB_ARN"

# ── Step 2: Bootstrap DR Terraform remote state ────────────
echo ""
echo "[2/6] Setting up DR Terraform remote state..."

aws s3api create-bucket \
  --bucket "$TFSTATE_BUCKET" \
  --region "$DR_REGION" \
  --create-bucket-configuration LocationConstraint="$DR_REGION" 2>/dev/null || echo "  Bucket already exists"

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
  --region "$DR_REGION" 2>/dev/null || echo "  DynamoDB table already exists"

echo "  DR remote state configured"

# ── Step 3: Terraform init + plan ─────────────────────────
echo ""
echo "[3/6] Initializing DR Terraform..."
cd terraform/dr
terraform init -upgrade -input=false

echo ""
echo "[4/6] Validating and planning DR deployment..."
terraform validate
terraform plan \
  -var="aws_account_id=$ACCOUNT_ID" \
  -var="primary_db_arn=$PRIMARY_DB_ARN" \
  -var="primary_velero_bucket_arn=arn:aws:s3:::${PROJECT}-primary-velero-primary" \
  -out=dr.tfplan

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Review the plan above, then press ENTER to deploy"
echo "  Ctrl+C to cancel"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r

# ── Step 5: Apply ─────────────────────────────────────────
echo ""
echo "[5/6] Deploying DR infrastructure (~15 minutes)..."
terraform apply dr.tfplan

# ── Step 6: Configure kubectl + install K8s tools on DR ───
echo ""
echo "[6/6] Configuring kubectl for DR cluster and deploying K8s tools..."
DR_EKS_CLUSTER=$(terraform output -raw eks_cluster_name)
aws eks update-kubeconfig --region "$DR_REGION" --name "$DR_EKS_CLUSTER"

cd ../../
# Reuse SNS topic from primary for DR alerts (same account)
PRIMARY_SNS_ARN=$(cd terraform/primary && terraform output -raw sns_topic_arn 2>/dev/null || \
  aws sns list-topics --region "$PRIMARY_REGION" \
    --query "Topics[?contains(TopicArn,'${PROJECT}-primary-dr-alerts')].TopicArn" \
    --output text | head -1)

ansible-playbook \
  -i ansible/inventory/hosts.yaml \
  ansible/playbooks/deploy-k8s-tools.yaml \
  -e "cluster_name=$DR_EKS_CLUSTER" \
  -e "region=$DR_REGION" \
  -e "velero_bucket=${PROJECT}-dr-velero" \
  -e "velero_role_arn=$(cd terraform/dr && terraform output -raw velero_iam_role_arn)" \
  -e "lb_controller_role_arn=$(cd terraform/dr && terraform output -raw lb_controller_role_arn)" \
  -e "drift_detection_role_arn=" \
  -e "sns_topic_arn=${PRIMARY_SNS_ARN:-}" \
  -e "opensearch_password=${OPENSEARCH_PASSWORD:-Admin@DR2024!}" \
  -e "groq_api_key=${GROQ_API_KEY:-}" \
  -e "slack_webhook=${SLACK_WEBHOOK:-}"

# Update ConfigMap region/environment for DR cluster
kubectl patch configmap dr-app-config -n dr-app \
  --patch '{"data":{"region":"us-west-2","environment":"dr"}}' || true

echo ""
echo "=============================================="
echo "  DR deployment complete!"
echo "=============================================="
cd terraform/dr && terraform output
