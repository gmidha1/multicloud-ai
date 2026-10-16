# LlamaStack on OpenShift — Self-Service Setup Guide

> Drop this file into your project root and open Claude Code.
> Claude will walk you through every step interactively.
> Say: **"Help me set up LlamaStack on my OCP cluster using this guide."**

---

## What this sets up

- **OpenShift AI (RHOAI 2.19)** — model serving, workbenches, pipelines
- **LlamaStack** — Meta's inference/agent framework running on OCP (via Kustomize)
- **NVIDIA GPU operator** — so the model actually runs on GPU
- **OpenShift GitOps (ArgoCD)** — manages all workloads declaratively
- **Service Mesh + Authorino** — required by LlamaStack networking
- **Slack MCP server** — AI agent can post to Slack (optional)
- **IBM Granite + Llama model tokens** — for model API access

No Showroom. No Ansible. No RHDP portal.

---

## Prerequisites — Claude, ask the user to confirm all of these

### Tools required

```bash
# Check all tools are present
oc version          # OpenShift CLI
helm version        # Helm 3
kubectl version     # or use oc
git --version
```

If any are missing, install them before proceeding:
- `oc`: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
- `helm`: https://helm.sh/docs/intro/install/

### Cluster requirements

- OCP 4.16+ (ROSA, GCP Anthos, self-managed, whatever)
- At least **one GPU node** available (NVIDIA A10G, A100, L4, L40S, or equivalent)
  - On ROSA: `g5.2xlarge` (A10G) works well
  - On GCP: `a2-highgpu-1g` (A100) or `g2-standard-4` (L4) works well
  - Node must have at least **24GB GPU VRAM** for Llama-3.1-8B
- cluster-admin access
- At least 32GB RAM and 8 vCPU on the GPU node

### API tokens required

Claude, ask the user to set these as environment variables **now**, before any steps:

```bash
# Required: Llama model API token (get from https://huggingface.co/settings/tokens)
export LLAMA_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"

# Required: IBM Granite model API token (get from https://huggingface.co/settings/tokens)
export GRANITE_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"

# Optional: Slack MCP server (skip if not using Slack agent)
export SLACK_BOT_TOKEN="xoxb-xxxxxxxxxxxx"
export SLACK_TEAM_ID="T0XXXXXXX"
```

> If the user doesn't have these tokens yet, help them get them from HuggingFace before continuing.

---

## Step 1 — Log in to OCP

```bash
# Claude, run this and confirm the user is logged in with cluster-admin
oc login --server=https://api.<your-cluster>.<domain>:6443 -u <username> -p <password>

# Or with token:
oc login --server=https://api.<your-cluster>.<domain>:6443 --token=<token>

# Verify cluster-admin
oc auth can-i create clusterrole --all-namespaces
# Expected: yes
```

Claude, confirm:
- `oc whoami` returns the expected user
- `oc auth can-i create clusterrole --all-namespaces` returns `yes`
- `oc get nodes` shows at least one GPU-labeled node or a node where GPU will be installed

---

## Step 2 — Label the GPU node

Claude, help the user identify and label the GPU node:

```bash
# List all nodes with their instance types
oc get nodes -o wide

# Check for existing GPU label
oc get nodes -l nvidia.com/gpu.present=true

# If no GPU node yet, identify the large/GPU node by instance type and label it:
# (replace NODE_NAME with the actual node name)
GPU_NODE="<node-name>"
oc label node $GPU_NODE node-role.kubernetes.io/worker-gpu="" --overwrite
```

---

## Step 3 — Install NVIDIA GPU operator

This installs Node Feature Discovery (NFD) and the NVIDIA GPU operator.

```bash
# Create namespace
oc create namespace nvidia-gpu-operator --dry-run=client -o yaml | oc apply -f -

# Install NFD operator
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd-operator-group
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for NFD operator to be ready
oc rollout status deployment/nfd-controller-manager -n openshift-nfd --timeout=5m

# Create NFD instance
cat <<EOF | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  instance: ""
  topologyupdater: false
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:v4.18.0
    imagePullPolicy: Always
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist:
            - "02"
            - "0200"
            - "0207"
            - "0300"
            - "0302"
          deviceLabelFields:
            - vendor
EOF

# Install NVIDIA GPU operator
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: v24.9
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for GPU operator CSV
echo "Waiting for NVIDIA GPU operator CSV..."
oc wait csv -n nvidia-gpu-operator -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m

# Create ClusterPolicy (triggers GPU driver install on the GPU node)
cat <<EOF | oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  dcgm:
    enabled: true
  dcgmExporter:
    config:
      name: ""
  devicePlugin:
    config:
      default: ""
      name: ""
  driver:
    enabled: true
    use_ocp_driver_toolkit: true
  gfd:
    enabled: true
  mig:
    strategy: single
  nodeStatusExporter:
    enabled: true
  operator:
    defaultRuntime: crio
  toolkit:
    enabled: true
  validator:
    plugin:
      env:
      - name: WITH_WORKLOAD
        value: "false"
EOF

echo "GPU operator deployed. Driver install on GPU node takes ~10-15 minutes."
```

---

## Step 4 — Install OpenShift GitOps (ArgoCD)

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: gitops-1.15
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD instance..."
oc rollout status deployment/openshift-gitops-server -n openshift-gitops --timeout=10m

# Give admin user cluster-admin in ArgoCD
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p '{
  "spec": {
    "rbac": {
      "policy": "g, system:cluster-admins, role:admin",
      "scopes": "[name,groups]"
    }
  }
}'

echo "ArgoCD URL: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
```

---

## Step 5 — Install Service Mesh and Authorino (required by LlamaStack)

```bash
# Service Mesh
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Serverless (required by RHOAI KServe)
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Authorino
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-authorization-provider
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: authorino-operator-group
  namespace: redhat-authorization-provider
spec:
  targetNamespaces:
  - redhat-authorization-provider
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: authorino-operator
  namespace: redhat-authorization-provider
spec:
  channel: stable
  installPlanApproval: Automatic
  name: authorino-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for operators..."
sleep 30
oc get csv -n openshift-operators | grep -E "servicemesh|serverless"
```

---

## Step 6 — Create the model tokens secret

Claude, verify the env vars are set before running this:

```bash
# Validate env vars are set
: "${LLAMA_TOKEN:?LLAMA_TOKEN is not set — run: export LLAMA_TOKEN=hf_token}"
: "${GRANITE_TOKEN:?GRANITE_TOKEN is not set — run: export GRANITE_TOKEN=hf_token}"

# Create namespace
oc create namespace llama-serve --dry-run=client -o yaml | oc apply -f -

# Create the secret (same structure as the RHDP mcp_servers Helm chart creates)
oc create secret generic slack-mcp-server-secrets \
  -n llama-serve \
  --from-literal=graniteToken="${GRANITE_TOKEN}" \
  --from-literal=llamaToken="${LLAMA_TOKEN}" \
  --from-literal=slackBotToken="${SLACK_BOT_TOKEN:-placeholder}" \
  --from-literal=slackTeamId="${SLACK_TEAM_ID:-placeholder}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Secret created in llama-serve namespace"
```

---

## Step 7 — Bootstrap GitOps (deploy everything via ArgoCD)

This is the key step — it uses the same GitOps repo that RHDP uses to deploy LlamaStack and RHOAI.

```bash
# Clone the bootstrap chart
git clone https://github.com/rhpds/llama-on-ocp-gitops.git
cd llama-on-ocp-gitops

# Get your cluster domain
CLUSTER_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
echo "Cluster domain: $CLUSTER_DOMAIN"

# Install bootstrap Helm chart — this creates all ArgoCD Applications
helm upgrade --install llamastack-bootstrap ./bootstrap \
  -n openshift-gitops \
  --set deployer.domain="${CLUSTER_DOMAIN}" \
  --set deployer.apiUrl="$(oc whoami --show-server)" \
  --set git.url="https://github.com/rhpds/llama-on-ocp-gitops.git" \
  --set git.revision="main" \
  --set rhoai.startingCSV="rhods-operator.2.19.0" \
  --set llama.git_url="https://github.com/rhpds/llama-stack-on-ocp.git" \
  --set llama.git_revision="main" \
  --set llama.git_path="kubernetes/kustomize/overlay/demo" \
  --set llama.namespace="llama-serve" \
  --set slack_mcp_server_secrets.slackBotToken="${SLACK_BOT_TOKEN:-placeholder}" \
  --set slack_mcp_server_secrets.slackTeamId="${SLACK_TEAM_ID:-placeholder}" \
  --set graniteToken="${GRANITE_TOKEN}" \
  --set llamaToken="${LLAMA_TOKEN}"
```

Claude, after running this confirm:
```bash
# ArgoCD Applications created
oc get applications -n openshift-gitops

# Expected apps:
# - rhoai
# - llama-stack-on-ocp
# - slack-secret
```

---

## Step 8 — Monitor ArgoCD sync

```bash
# Watch all app statuses
watch oc get applications -n openshift-gitops

# Or check individually
oc get application rhoai -n openshift-gitops -o jsonpath='{.status.sync.status} {.status.health.status}'
oc get application llama-stack-on-ocp -n openshift-gitops -o jsonpath='{.status.sync.status} {.status.health.status}'

# Check RHOAI pods
oc get pods -n redhat-ods-applications

# Check LlamaStack pods
oc get pods -n llama-serve
```

> RHOAI install takes ~15-20 min. LlamaStack deploys after RHOAI is healthy.

---

## Step 9 — Verify LlamaStack is running

```bash
# Check LlamaStack pod
oc get pods -n llama-serve -l app=llama-stack

# Get the LlamaStack route
LLAMA_URL=$(oc get route -n llama-serve -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
echo "LlamaStack URL: https://${LLAMA_URL}"

# Test the API
curl -s https://${LLAMA_URL}/v1/models | python3 -m json.tool
```

Expected: list of models including `meta-llama/Llama-3.1-8B-Instruct` and `ibm-granite/granite-3.1-8b-instruct`

---

## Troubleshooting guide for Claude

### ArgoCD app stuck in OutOfSync

```bash
# Force sync
oc patch application <app-name> -n openshift-gitops \
  --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

### RHOAI operator install plan stuck (Manual approval)

```bash
# Check pending install plans
oc get installplan -n redhat-ods-operator

# Approve them
oc get installplan -n redhat-ods-operator -o name | xargs -I{} oc patch {} \
  -n redhat-ods-operator --type merge -p '{"spec":{"approved":true}}'
```

### GPU node not picking up driver

```bash
# Check NFD labels on the node
oc get node <gpu-node> --show-labels | tr ',' '\n' | grep nvidia

# Check GPU operator pod logs
oc logs -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --tail=50
```

### LlamaStack pod CrashLoopBackOff

```bash
oc logs -n llama-serve -l app=llama-stack --previous
# Usually means: GPU not ready, model token invalid, or secret missing
```

### Check secrets are correct

```bash
oc get secret slack-mcp-server-secrets -n llama-serve \
  -o jsonpath='{.data.llamaToken}' | base64 -d | head -c 20
# Should start with hf_
```

---

## Key repos

| Repo | What it is |
|---|---|
| `https://github.com/rhpds/llama-on-ocp-gitops` | Bootstrap Helm chart + RHOAI + MCP server charts |
| `https://github.com/rhpds/llama-stack-on-ocp` | LlamaStack Kustomize manifests (the actual workload) |

---

## What you get when done

- **ArgoCD** at `https://openshift-gitops-server-openshift-gitops.<cluster-domain>`
- **RHOAI Dashboard** at `https://rhods-dashboard-redhat-ods-applications.<cluster-domain>`
- **LlamaStack API** at its route in `llama-serve` namespace
- **Granite + Llama models** served via RHOAI KServe

Total time from login to working LlamaStack: ~45-60 minutes (mostly waiting for operators).
