# LlamaStack Multi-Cluster Deployment with RHACM

Complete step-by-step guide for deploying LlamaStack to multiple GPU-enabled OpenShift clusters using Red Hat Advanced Cluster Management.

## Overview

This guide uses a **hybrid approach**:
- **RHACM Policies** for infrastructure (operators, GPU config, RHOAI)
- **GitOps ApplicationSet** for applications (LlamaStack, models, services)

**Total deployment time:** ~50-60 minutes per cluster (mostly automated)

## Architecture

```
RHACM Hub Cluster
├── Policies (Infrastructure)
│   ├── GPU Operator
│   ├── NFD Operator
│   ├── Service Mesh Operator
│   ├── Serverless Operator
│   ├── GitOps Operator
│   ├── Authorino Operator
│   ├── RHOAI Operator
│   ├── GPU Configuration
│   ├── Service Mesh Control Plane
│   ├── Knative Serving
│   └── DataScienceCluster
└── ApplicationSet (Applications)
    ├── Granite Model
    ├── LlamaStack Server
    ├── MCP Servers
    └── Streamlit UI
    ↓
Managed GPU Clusters (ROSA, ARO, etc.)
```

## Prerequisites

### Hub Cluster Requirements
- ✅ RHACM 2.9+ installed
- ✅ OpenShift GitOps operator installed
- ✅ Cluster admin access
- ✅ At least 1 managed cluster imported

### Managed Cluster Requirements
- ✅ OpenShift 4.18+
- ✅ GPU node(s) with NVIDIA A10G or better (g5.2xlarge minimum)
- ✅ Cluster admin access
- ✅ Internet connectivity for image pulls

### Required Tokens
- 🔑 Hugging Face token for Llama models (`LLAMA_TOKEN`)
- 🔑 Hugging Face token for Granite models (`GRANITE_TOKEN`)
- 🔑 (Optional) Slack bot token and team ID

---

## Part 1: Hub Cluster Setup (15 minutes)

### Step 1: Verify RHACM Installation

```bash
# Set context to hub cluster
oc config use-context hub-cluster

# Verify RHACM is running
oc get multiclusterhub -n open-cluster-management
# Should show: RHACM as "Running"

# Verify managed clusters
oc get managedclusters
# Should list your GPU clusters
```

### Step 2: Install OpenShift GitOps (if not already installed)

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator to be ready
oc wait --for=condition=Ready pod -l name=gitops-operator -n openshift-gitops-operator --timeout=300s
```

### Step 3: Create Policy Namespace

```bash
oc create namespace llama-stack-policies

# Note: We'll use openshift-gitops namespace for Placement and ApplicationSet resources
```

### Step 4: Clone This Repository

```bash
cd ~/Documents/claude_projects/llama-install

# Verify files exist
ls -la rhacm-deployment/
# Should see: policy-*.yaml, applicationset-*.yaml, etc.
```

---

## Part 2: Managed Cluster Preparation (5 minutes)

### Step 5: Label GPU Clusters

Label your managed clusters to enable targeting:

```bash
# List managed clusters
oc get managedclusters

# Label GPU-enabled clusters
export GPU_CLUSTER=rosa-dev # e.g., "rosa-gpu-prod"

export GPU_CLUSTER=aro-stage 

oc label managedcluster $GPU_CLUSTER gpu-enabled=true --overwrite
oc label managedcluster $GPU_CLUSTER environment=production --overwrite
#oc label managedcluster $GPU_CLUSTER vendor=OpenShift --overwrite

# Verify labels
oc get managedcluster $GPU_CLUSTER --show-labels
```

### Step 6: Create Secrets on Hub (for Propagation)

We'll create secrets on the hub that will be propagated to managed clusters:

```bash
# Set your tokens
export LLAMA_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"
export GRANITE_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"
export SLACK_BOT_TOKEN="xoxb-xxxxxxxxxxxx"  # Optional
export SLACK_TEAM_ID="T0XXXXXXX"  # Optional

# We'll create these as part of the ManifestWork in the next section
```

---

## Part 3: Deploy Infrastructure via Policies (35-45 minutes)

**⚠️ IMPORTANT TIMING NOTE:**
This section takes 35-45 minutes to complete. **You MUST wait for all policies to be "Compliant" and complete Step 9a verification before proceeding to Part 6.** Deploying models (Part 6, Step 15) before RHOAI/KServe are ready will fail with "resource type not found" errors.

### Step 7: Deploy Operator Installation Policy

This policy installs all required operators on GPU clusters.

```bash
oc apply -f rhacm-deployment/policy-operators.yaml
```

**Monitor progress:**

```bash
# Watch policy status
watch oc get policy -n llama-stack-policies

# Should show:
# NAME                      REMEDIATION ACTION   COMPLIANCE STATE   AGE
# llama-stack-operators     enforce              Compliant          2m
```

**Verify on managed cluster:**

```bash
# Switch to managed cluster context
oc config use-context $GPU_CLUSTER

# Check all operators
echo "=== Checking Operators Installation ==="
echo ""
echo "GPU Operator:"
oc get csv -n nvidia-gpu-operator | grep gpu-operator

echo ""
echo "NFD Operator:"
oc get csv -n openshift-nfd | grep nfd

echo ""
echo "Service Mesh Operator:"
oc get csv -n openshift-operators | grep servicemeshoperator

echo ""
echo "Serverless Operator:"
oc get csv -n openshift-operators | grep serverless-operator

echo ""
echo "GitOps Operator:"
oc get csv -n openshift-operators | grep gitops-operator

echo ""
echo "Authorino Operator:"
oc get csv -n redhat-authorization-provider | grep authorino-operator

echo ""
echo "RHOAI Operator:"
oc get csv -n redhat-ods-operator | grep rhods-operator

echo ""
echo "All should show 'Succeeded' phase (takes 15-20 min)"
```

### Step 8: Deploy GPU Configuration Policy

This configures NFD, GPU drivers, and RHOAI:

```bash
# Switch back to hub
oc config use-context hub-cluster

oc apply -f rhacm-deployment/policy-gpu-config.yaml
```

**Monitor GPU driver installation:**

```bash
# On managed cluster
oc config use-context $GPU_CLUSTER

# Watch GPU operator pods
watch oc get pods -n nvidia-gpu-operator

# Wait for nvidia-driver-daemonset to be Running (10-15 min)

# Verify GPU is available
oc get node -l node-role.kubernetes.io/worker-gpu -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu
```

### Step 9: Verify DataScienceCluster

```bash
# On managed cluster
oc get datasciencecluster default-dsc

# Should show phase: Ready (2-3 min)
```

### Step 9a: **CRITICAL - Verify KServe CRDs Are Installed**

Before proceeding to deploy models, verify that KServe is fully operational:

```bash
# On managed cluster
oc config use-context $GPU_CLUSTER

echo "=== Verifying KServe Prerequisites ==="
echo ""

# 1. Verify Service Mesh Control Plane is ready
echo "Checking Service Mesh Control Plane..."
oc get smcp data-science-smcp -n istio-system -o jsonpath='{.status.annotations.readyComponentCount}'
# Should show non-zero number

echo ""

# 2. Verify Knative Serving is ready
echo "Checking Knative Serving..."
oc get knativeserving knative-serving -n knative-serving -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Should return "True"

echo ""

# 3. Verify KServe CRDs exist (REQUIRED for model deployment)
echo "Checking KServe CRDs..."
oc get crd servingruntimes.serving.kserve.io
oc get crd inferenceservices.serving.kserve.io
# Both should show the CRD name
# If you get "error: the server doesn't have a resource type", STOP and wait

echo ""

# 4. Verify KServe controller is running
echo "Checking KServe controller..."
oc get pods -n redhat-ods-applications -l control-plane=kserve-controller-manager
# Should show kserve-controller-manager pod as Running

echo ""
echo "✅ KServe is ready for model deployment"
```

**⚠️ DO NOT PROCEED TO PART 6 UNTIL ALL VERIFICATIONS PASS**

### Quick Readiness Check

Run this comprehensive check to verify the managed cluster is ready for model deployment:

```bash
# On managed cluster
echo "=== Comprehensive Readiness Check ==="
echo ""

# Check 1: KServe CRDs
echo -n "KServe CRDs: "
if oc get crd servingruntimes.serving.kserve.io inferenceservices.serving.kserve.io &>/dev/null; then
  echo "✅ PASS"
else
  echo "❌ FAIL - KServe CRDs not installed"
fi

# Check 2: DataScienceCluster
echo -n "DataScienceCluster: "
if oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Ready; then
  echo "✅ PASS"
else
  echo "❌ FAIL - DataScienceCluster not ready"
fi

# Check 3: Service Mesh
echo -n "Service Mesh Control Plane: "
if oc get smcp data-science-smcp -n istio-system &>/dev/null; then
  echo "✅ PASS"
else
  echo "❌ FAIL - Service Mesh not deployed"
fi

# Check 4: Knative Serving
echo -n "Knative Serving: "
if oc get knativeserving knative-serving -n knative-serving &>/dev/null; then
  echo "✅ PASS"
else
  echo "❌ FAIL - Knative Serving not deployed"
fi

# Check 5: KServe Controller
echo -n "KServe Controller: "
if oc get pods -n redhat-ods-applications -l control-plane=kserve-controller-manager --field-selector=status.phase=Running 2>/dev/null | grep -q Running; then
  echo "✅ PASS"
else
  echo "❌ FAIL - KServe controller not running"
fi

# Check 6: GPU Availability
echo -n "GPU Nodes: "
if oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | grep -q Ready; then
  echo "✅ PASS"
else
  echo "❌ FAIL - No GPU nodes labeled"
fi

echo ""
echo "=== Summary ==="
if oc get crd servingruntimes.serving.kserve.io &>/dev/null && \
   oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Ready && \
   oc get smcp data-science-smcp -n istio-system &>/dev/null && \
   oc get knativeserving knative-serving -n knative-serving &>/dev/null && \
   oc get pods -n redhat-ods-applications -l control-plane=kserve-controller-manager --field-selector=status.phase=Running 2>/dev/null | grep -q Running; then
  echo "✅ ALL CHECKS PASSED - Ready for Part 6 (Model Deployment)"
else
  echo "❌ NOT READY - Wait for infrastructure deployment to complete"
  echo "   Run policies may take 35-45 minutes to fully deploy"
fi
```

---

## Part 4: Prepare Git Repository (10 minutes)

### Step 10: Fork and Customize LlamaStack Repository

**Option A: Use existing repository (quick start)**

```bash
# We'll use the upstream repo directly
export GIT_REPO="https://github.com/rhpds/llama-stack-on-ocp.git"
export GIT_BRANCH="main"
```

**Option B: Fork and customize (recommended for production)**

```bash
# Fork https://github.com/rhpds/llama-stack-on-ocp to your org
export GIT_REPO="https://github.com/<your-org>/llama-stack-on-ocp.git"

# Clone your fork
git clone $GIT_REPO ~/llama-stack-custom
cd ~/llama-stack-custom

# Customize kustomize overlay
cd kubernetes/kustomize/overlay/demo

# Edit kustomization.yaml to add your customizations
# (We'll provide an overlay in next steps)

git add .
git commit -m "Customize for multi-cluster deployment"
git push origin main
```

---

## Part 5: Deploy Secrets via ManifestWork (5 minutes)

### Step 11: Create Secrets ManifestWork

We need to deploy secrets to each managed cluster:

```bash
# Switch to hub
oc config use-context hub-cluster

# Create secrets ManifestWork for each cluster
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
          graniteToken: "${GRANITE_TOKEN}"
          llamaToken: "${LLAMA_TOKEN}"
          slackBotToken: "${SLACK_BOT_TOKEN:-placeholder}"
          slackTeamId: "${SLACK_TEAM_ID:-placeholder}"
      
      - apiVersion: v1
        kind: Secret
        metadata:
          name: slack-secret
          namespace: llama-serve
        type: Opaque
        stringData:
          SLACK_BOT_TOKEN: "${SLACK_BOT_TOKEN:-placeholder}"
          SLACK_TEAM_ID: "${SLACK_TEAM_ID:-placeholder}"
          slack-bot-token: "${SLACK_BOT_TOKEN:-placeholder}"
          slack-team-id: "${SLACK_TEAM_ID:-placeholder}"
          llama-token: "${LLAMA_TOKEN}"
          granite-token: "${GRANITE_TOKEN}"
      
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
          AWS_ACCESS_KEY_ID: "${GRANITE_TOKEN}"
          AWS_DEFAULT_REGION: us-east-1
          AWS_S3_BUCKET: placeholder
          AWS_S3_ENDPOINT: https://huggingface.co
          AWS_SECRET_ACCESS_KEY: "${GRANITE_TOKEN}"
EOF
```

**Verify secrets were created:**

```bash
# Check ManifestWork status
oc get manifestwork llamastack-secrets -n $GPU_CLUSTER

# On managed cluster
oc config use-context $GPU_CLUSTER
oc get secrets -n llama-serve
```

---

## Part 6: Deploy LlamaStack via GitOps (15-20 minutes)

### Step 12: Create Custom Kustomize Overlay

First, let's create a custom overlay with our Granite model configuration:

```bash
# Switch to hub
oc config use-context hub-cluster

# Apply the custom overlay ConfigMap
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: llamastack-granite-overlay
  namespace: openshift-gitops
data:
  granite-model.yaml: |
    apiVersion: serving.kserve.io/v1alpha1
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
    ---
    apiVersion: serving.kserve.io/v1beta1
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
EOF
```

### Step 13: Create Placement for GPU Clusters

```bash
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: gpu-clusters
  namespace: openshift-gitops
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: gpu-enabled
              operator: In
              values:
                - "true"
  numberOfClusters: 10
EOF

# Verify placement
oc get placement gpu-clusters -n openshift-gitops -o yaml

# Check PlacementDecisions (created automatically by RHACM)
oc get placementdecisions -n openshift-gitops -l cluster.open-cluster-management.io/placement=gpu-clusters
```

### Step 14: Deploy ApplicationSet

```bash
cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: llamastack-deployment
  namespace: openshift-gitops
spec:
  generators:
    - clusterDecisionResource:
        configMapRef: acm-placement
        labelSelector:
          matchLabels:
            cluster.open-cluster-management.io/placement: gpu-clusters
        requeueAfterSeconds: 180
  template:
    metadata:
      name: 'llamastack-rosa-gpu'
      labels:
        app: llamastack
        cluster: 'rosa-gpu'
    spec:
      project: default
      source:
        repoURL: https://github.com/rhpds/llama-stack-on-ocp.git
        targetRevision: main
        path: kubernetes/kustomize/overlay/demo
      destination:
        server: 'https://api.rosa-jvtjx.tm8i.p3.openshiftapps.com:443'
        namespace: llama-serve
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - RespectIgnoreDifferences=true
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
      ignoreDifferences:
        - group: serving.kserve.io
          kind: InferenceService
          jsonPointers:
            - /status
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: acm-placement
  namespace: openshift-gitops
data:
  name: gpu-clusters
  namespace: openshift-gitops
EOF
```

### Step 14a: **VERIFY KServe is Ready on Managed Cluster**

**⚠️ CRITICAL**: Before deploying the model, confirm KServe CRDs exist:

```bash
# Switch to hub cluster
oc config use-context hub-cluster

# Check if KServe policy is compliant
oc get policy -n llama-stack-policies

# Verify on managed cluster (via oc or RHACM console)
# Option 1: Direct check (if you have access to managed cluster)
oc config use-context $GPU_CLUSTER
oc get crd servingruntimes.serving.kserve.io inferenceservices.serving.kserve.io

# Option 2: Check via RHACM (from hub cluster)
oc config use-context hub-cluster
oc get managedclusterinfo -n $GPU_CLUSTER -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterInfoSynced")].status}'
# Should return "True"
```

**If KServe CRDs don't exist**, wait for RHOAI policy to complete (Step 7-9). This can take 20-30 minutes.

### Step 15: Deploy Granite Model via ManifestWork

Since the upstream kustomize doesn't include our optimized Granite config, we'll deploy it separately:

```bash
# Switch to hub cluster
oc config use-context hub-cluster

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
        - type: WellKnownStatus
EOF
```

---

## Part 7: Verification (10 minutes)

### Step 16: Monitor Deployment from Hub

```bash
# Switch to hub cluster
oc config use-context hub-cluster

# Check policy compliance
oc get policy -n llama-stack-policies
# All should be "Compliant"

# Check ApplicationSet
oc get applicationset -n openshift-gitops
oc get application -n openshift-gitops | grep llamastack

# Check ManifestWork status
oc get manifestwork -n $GPU_CLUSTER
# All should show "Applied: true"
```

### Step 17: Verify on Managed Cluster

```bash
# Switch to managed cluster
oc config use-context $GPU_CLUSTER

# Check GPU availability
oc get nodes -l node-role.kubernetes.io/worker-gpu -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu

# Check all pods in llama-serve
oc get pods -n llama-serve

# Expected output (after model loads):
# NAME                                        READY   STATUS
# granite32-8b-predictor-xxxxx                4/4     Running
# llamastack-deployment-xxxxx                 1/1     Running
# ocp-mcp-server-xxxxx                        1/1     Running
# slack-mcp-server-xxxxx                      1/1     Running
# streamlit-xxxxx                             2/2     Running
```

### Step 18: Check Granite Model Loading

The model download and loading takes 5-10 minutes:

```bash
# Check InferenceService status
oc get inferenceservice granite32-8b -n llama-serve

# Watch model loading progress
POD=$(oc get pod -n llama-serve -l serving.kserve.io/inferenceservice=granite32-8b -o jsonpath='{.items[0].metadata.name}')
oc logs -n llama-serve $POD -c kserve-container --tail=50 -f

# Look for: "Application startup complete"
```

### Step 19: Get Access URLs

```bash
# Get cluster domain
CLUSTER_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')

echo "=== LlamaStack Access URLs ==="
echo "Streamlit UI:     https://streamlit-llama-serve.${CLUSTER_DOMAIN}"
echo "Granite Model:    https://granite32-8b-llama-serve.${CLUSTER_DOMAIN}"
echo "LlamaStack API:   https://llamastack-server-llama-serve.${CLUSTER_DOMAIN}"
```

### Step 20: Test the Deployment

```bash
# Test Granite model endpoint
GRANITE_URL="https://granite32-8b-llama-serve.${CLUSTER_DOMAIN}/v1/models"
curl -k $GRANITE_URL

# Should return model info

# Test Streamlit UI in browser
echo "Open: https://streamlit-llama-serve.${CLUSTER_DOMAIN}"
```

---

## Part 8: Multi-Cluster Deployment

### Step 21: Deploy to Additional Clusters

To deploy to additional GPU clusters:

```bash
# Label the new cluster
export GPU_CLUSTER_2="<second-cluster-name>"
oc label managedcluster $GPU_CLUSTER_2 gpu-enabled=true

# Create secrets ManifestWork
# (Repeat Step 11 with GPU_CLUSTER_2)

# Create Granite model ManifestWork
# (Repeat Step 15 with GPU_CLUSTER_2)
```

The ApplicationSet will automatically detect and deploy!

---

## Troubleshooting

### Issue: ManifestWork Failed - "server doesn't have a resource type"

**Symptom:**
```
oc get manifestwork llamastack-granite-model -n rosa-gpu1
# Shows: Applied: False
# Message: "the server doesn't have a resource type 'ServingRuntime'"
```

**Root Cause:** RHOAI and KServe are not fully installed on the managed cluster.

**Solution:**

```bash
# 1. Check if RHOAI policy is compliant
oc get policy llama-stack-operators -n llama-stack-policies
oc get policy llama-stack-gpu-config -n llama-stack-policies
# Both should show "Compliant"

# 2. If policies are compliant, verify on managed cluster
oc config use-context $GPU_CLUSTER

# Check RHOAI operator
oc get csv -n redhat-ods-operator | grep rhods-operator
# Should show "Succeeded"

# Check DataScienceCluster
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'
# Should return "Ready"

# 3. Verify KServe CRDs are installed
oc get crd | grep kserve
# Should show:
# inferenceservices.serving.kserve.io
# servingruntimes.serving.kserve.io

# 4. If CRDs don't exist, check KServe component
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.managementState}'
# Should return "Managed"

# 5. Wait for KServe controller
oc get pods -n redhat-ods-applications -l control-plane=kserve-controller-manager
# Should show Running pod

# 6. Once ready, delete and recreate the ManifestWork
oc delete manifestwork llamastack-granite-model -n $GPU_CLUSTER
# Then re-apply Step 15
```

**Prevention:** Always complete Step 9a before proceeding to Part 6.

**Recovery Steps for Current Deployment:**

If you already have a failed ManifestWork, here's how to recover:

```bash
# From hub cluster
oc config use-context <hub-cluster>

# 1. Check current ManifestWork status
oc get manifestwork -n $GPU_CLUSTER
oc describe manifestwork llamastack-granite-model -n $GPU_CLUSTER | grep -A5 "Status:"

# 2. Wait for RHOAI to be ready on managed cluster
# Use the Quick Readiness Check from Step 9a

# 3. Once ready, force reapply by deleting and recreating
oc delete manifestwork llamastack-granite-model -n $GPU_CLUSTER

# 4. Wait 30 seconds for cleanup
sleep 30

# 5. Reapply the ManifestWork from Step 15
# (Re-run the cat <<EOF | oc apply -f - command)

# 6. Monitor the reapplication
watch oc get manifestwork llamastack-granite-model -n $GPU_CLUSTER

# Should transition to Applied: True within 2-3 minutes
```

### Issue: Policy Not Compliant

```bash
# Check policy details
oc describe policy <policy-name> -n llama-stack-policies

# Check on managed cluster
oc config use-context $GPU_CLUSTER
oc get events -n <namespace> --sort-by='.lastTimestamp'
```

### Issue: Granite Model Not Ready

```bash
# Check pod status
oc get pods -n llama-serve -l serving.kserve.io/inferenceservice=granite32-8b

# Check logs
POD=$(oc get pod -n llama-serve -l serving.kserve.io/inferenceservice=granite32-8b -o jsonpath='{.items[0].metadata.name}')
oc logs -n llama-serve $POD -c kserve-container --tail=100

# Common issues:
# - Model still downloading (wait 5-10 min)
# - GPU not available (check GPU operator)
# - Resource constraints (check node resources)
```

### Issue: ApplicationSet Not Syncing

```bash
# Check ApplicationSet status
oc get applicationset llamastack-deployment -n openshift-gitops -o yaml

# Check placement
oc get placement gpu-clusters -n openshift-gitops -o yaml

# Check PlacementDecisions
oc get placementdecisions -n openshift-gitops -l cluster.open-cluster-management.io/placement=gpu-clusters

# Force sync
oc patch application llamastack-<cluster> -n openshift-gitops --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

---

## Day 2 Operations

### Update LlamaStack Version

```bash
# If using your own Git repo:
cd ~/llama-stack-custom
git pull upstream main
git push origin main

# ApplicationSet will auto-sync (or manual sync from ArgoCD UI)
```

### Scale to More Clusters

```bash
# Just label new clusters
oc label managedcluster <new-cluster> gpu-enabled=true

# Everything deploys automatically!
```

### Remove from Cluster

```bash
# Remove label
oc label managedcluster <cluster-name> gpu-enabled-

# ApplicationSet will prune resources
```

---

## Next Steps

- ✅ Set up monitoring with Prometheus/Grafana
- ✅ Configure backup with OADP
- ✅ Implement External Secrets Operator for secret management
- ✅ Set up custom domains and certificates
- ✅ Configure resource quotas and limits
- ✅ Implement network policies

---

## Support

For issues:
- RHACM: https://access.redhat.com/support
- LlamaStack: https://github.com/rhpds/llama-stack-on-ocp/issues
- This guide: https://github.com/anthropics/claude-code/issues
