#!/bin/bash
set -e

# LlamaStack RHACM Deployment Script
# This script automates the deployment of LlamaStack to GPU clusters via RHACM

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 is required but not installed. Please install it first."
        exit 1
    fi
}

# Check prerequisites
log_info "Checking prerequisites..."
check_command oc
check_command jq

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
log_info "=== LlamaStack RHACM Deployment ==="
echo

# Check if environment variables are set
if [ -z "$GPU_CLUSTER" ]; then
    echo "Available managed clusters:"
    oc get managedclusters --no-headers | awk '{print "  - " $1}'
    echo
    read -p "Enter managed cluster name: " GPU_CLUSTER
fi

if [ -z "$LLAMA_TOKEN" ]; then
    read -sp "Enter Llama token (hf_xxx): " LLAMA_TOKEN
    echo
fi

if [ -z "$GRANITE_TOKEN" ]; then
    read -sp "Enter Granite token (hf_xxx): " GRANITE_TOKEN
    echo
fi

if [ -z "$SLACK_BOT_TOKEN" ]; then
    read -p "Enter Slack bot token (optional, press enter to skip): " SLACK_BOT_TOKEN
    SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN:-placeholder}
fi

if [ -z "$SLACK_TEAM_ID" ]; then
    read -p "Enter Slack team ID (optional, press enter to skip): " SLACK_TEAM_ID
    SLACK_TEAM_ID=${SLACK_TEAM_ID:-placeholder}
fi

echo
log_info "Configuration:"
echo "  Cluster: $GPU_CLUSTER"
echo "  Llama Token: ${LLAMA_TOKEN:0:10}..."
echo "  Granite Token: ${GRANITE_TOKEN:0:10}..."
echo "  Slack Bot Token: ${SLACK_BOT_TOKEN:0:10}..."
echo

read -p "Continue with deployment? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_warn "Deployment cancelled"
    exit 0
fi

echo
log_info "Starting deployment..."

# Step 1: Label cluster
log_info "[1/6] Labeling GPU cluster..."
oc label managedcluster $GPU_CLUSTER \
    gpu-enabled=true \
    environment=production \
    vendor=OpenShift \
    --overwrite

if [ $? -eq 0 ]; then
    log_info "✓ Cluster labeled successfully"
else
    log_error "Failed to label cluster"
    exit 1
fi

# Step 2: Create policy namespace
log_info "[2/6] Creating policy namespace..."
oc create namespace llama-stack-policies 2>/dev/null || log_warn "Namespace already exists"

# Step 3: Deploy infrastructure policies
log_info "[3/6] Deploying infrastructure policies..."

if [ -f "$SCRIPT_DIR/policy-operators.yaml" ]; then
    oc apply -f "$SCRIPT_DIR/policy-operators.yaml"
    log_info "✓ Operator policies deployed"
else
    log_warn "policy-operators.yaml not found, skipping"
fi

if [ -f "$SCRIPT_DIR/policy-gpu-config.yaml" ]; then
    oc apply -f "$SCRIPT_DIR/policy-gpu-config.yaml"
    log_info "✓ GPU config policies deployed"
else
    log_warn "policy-gpu-config.yaml not found, skipping"
fi

log_info "Waiting for policies to be applied (this may take 20-30 minutes)..."
log_info "You can monitor progress with: watch oc get policy -n llama-stack-policies"

# Step 4: Deploy secrets
log_info "[4/6] Deploying secrets to managed cluster..."

cat <<EOF | oc apply -f -
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: llamastack-secrets
  namespace: $GPU_CLUSTER
spec:
  workload:
    manifests:
      - apiVersion: v1
        kind: Namespace
        metadata:
          name: llama-serve
          labels:
            modelmesh-enabled: "true"
            opendatahub.io/dashboard: "true"

      - apiVersion: v1
        kind: Secret
        metadata:
          name: slack-mcp-server-secrets
          namespace: llama-serve
        type: Opaque
        stringData:
          graniteToken: "$GRANITE_TOKEN"
          llamaToken: "$LLAMA_TOKEN"
          slackBotToken: "$SLACK_BOT_TOKEN"
          slackTeamId: "$SLACK_TEAM_ID"

      - apiVersion: v1
        kind: Secret
        metadata:
          name: slack-secret
          namespace: llama-serve
        type: Opaque
        stringData:
          SLACK_BOT_TOKEN: "$SLACK_BOT_TOKEN"
          SLACK_TEAM_ID: "$SLACK_TEAM_ID"
          slack-bot-token: "$SLACK_BOT_TOKEN"
          slack-team-id: "$SLACK_TEAM_ID"
          llama-token: "$LLAMA_TOKEN"
          granite-token: "$GRANITE_TOKEN"

      - apiVersion: v1
        kind: Secret
        metadata:
          name: aws-connection-granite-model
          namespace: llama-serve
          labels:
            opendatahub.io/dashboard: "true"
            opendatahub.io/managed: "true"
          annotations:
            opendatahub.io/connection-type: s3
            openshift.io/display-name: granite-model
        type: Opaque
        stringData:
          AWS_ACCESS_KEY_ID: "$GRANITE_TOKEN"
          AWS_DEFAULT_REGION: us-east-1
          AWS_S3_BUCKET: placeholder
          AWS_S3_ENDPOINT: https://huggingface.co
          AWS_SECRET_ACCESS_KEY: "$GRANITE_TOKEN"
EOF

if [ $? -eq 0 ]; then
    log_info "✓ Secrets deployed via ManifestWork"
else
    log_error "Failed to deploy secrets"
    exit 1
fi

# Step 5: Deploy Granite model
log_info "[5/6] Deploying Granite model..."

cat <<EOF | oc apply -f -
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: llamastack-granite-model
  namespace: $GPU_CLUSTER
spec:
  workload:
    manifests:
      - apiVersion: serving.kserve.io/v1alpha1
        kind: ServingRuntime
        metadata:
          name: granite32-8b
          namespace: llama-serve
        spec:
          annotations:
            prometheus.io/path: /metrics
            prometheus.io/port: "8080"
          containers:
          - name: kserve-container
            image: quay.io/modh/vllm@sha256:4f550996130e7d16cacb24ca9a2865e7cf51eddaab014ceaf31a1ea6ef86d4ec
            command:
            - python
            - -m
            - vllm.entrypoints.openai.api_server
            args:
            - --port=8080
            - --model=/mnt/models
            - --max-model-len
            - "4096"
            - --gpu-memory-utilization
            - "0.9"
            env:
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  key: graniteToken
                  name: slack-mcp-server-secrets
            ports:
            - containerPort: 8080
              name: http1
              protocol: TCP
            volumeMounts:
            - mountPath: /dev/shm
              name: shm
          multiModel: false
          supportedModelFormats:
          - autoSelect: true
            name: vLLM
          volumes:
          - name: shm
            emptyDir:
              medium: Memory
              sizeLimit: 2Gi

      - apiVersion: serving.kserve.io/v1beta1
        kind: InferenceService
        metadata:
          name: granite32-8b
          namespace: llama-serve
          annotations:
            serving.kserve.io/deploymentMode: Serverless
            serving.knative.openshift.io/enablePassthrough: "true"
            sidecar.istio.io/inject: "true"
            sidecar.istio.io/rewriteAppHTTPProbers: "true"
            serving.knative.dev/progress-deadline: "1200s"
        spec:
          predictor:
            maxReplicas: 1
            minReplicas: 1
            model:
              modelFormat:
                name: vLLM
              name: ""
              resources:
                limits:
                  cpu: "2"
                  memory: 16Gi
                  nvidia.com/gpu: "1"
                requests:
                  cpu: "2"
                  memory: 8Gi
                  nvidia.com/gpu: "1"
              runtime: granite32-8b
              storageUri: oci://quay.io/redhat-ai-services/modelcar-catalog:granite-3.2-8b-instruct
            tolerations:
            - effect: NoSchedule
              key: nvidia.com/gpu
              operator: Equal
              value: "True"

  manifestConfigs:
    - resourceIdentifier:
        group: serving.kserve.io
        resource: inferenceservices
        name: granite32-8b
        namespace: llama-serve
      feedbackRules:
        - type: WellKnown
EOF

if [ $? -eq 0 ]; then
    log_info "✓ Granite model deployed via ManifestWork"
else
    log_error "Failed to deploy Granite model"
    exit 1
fi

# Step 6: Deploy ApplicationSet (if available)
log_info "[6/6] Deploying LlamaStack ApplicationSet..."

if [ -f "$SCRIPT_DIR/applicationset-llamastack.yaml" ]; then
    oc apply -f "$SCRIPT_DIR/applicationset-llamastack.yaml"
    log_info "✓ ApplicationSet deployed"
else
    log_warn "applicationset-llamastack.yaml not found, skipping GitOps deployment"
    log_info "You can deploy LlamaStack components manually or via additional ManifestWorks"
fi

echo
log_info "=== Deployment Complete ==="
echo
echo "Next steps:"
echo "  1. Monitor policy compliance:"
echo "     oc get policy -n llama-stack-policies"
echo
echo "  2. Check ManifestWork status:"
echo "     oc get manifestwork -n $GPU_CLUSTER"
echo
echo "  3. Monitor on managed cluster (after infrastructure is ready ~30 min):"
echo "     oc --context=$GPU_CLUSTER get pods -n llama-serve"
echo
echo "  4. Get access URLs (after deployment complete ~50 min):"
echo "     ./get-urls.sh $GPU_CLUSTER"
echo
log_info "Full deployment takes approximately 40-50 minutes"
log_info "Model download and loading: 5-10 minutes after infrastructure is ready"
