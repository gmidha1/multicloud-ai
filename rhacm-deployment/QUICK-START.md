# LlamaStack RHACM Quick Start

5-minute quick reference for deploying LlamaStack with RHACM.

## Prerequisites Checklist

- [ ] RHACM 2.9+ on hub cluster
- [ ] OpenShift GitOps on hub cluster
- [ ] At least 1 GPU cluster (g5.2xlarge+) imported to RHACM
- [ ] HuggingFace tokens ready (`LLAMA_TOKEN`, `GRANITE_TOKEN`)

## Quick Deploy (Copy-Paste Ready)

### 1. Set Environment Variables

```bash
# Hub cluster context
export HUB_CONTEXT="<your-hub-context>"
export GPU_CLUSTER="<managed-cluster-name>"

# Tokens
export LLAMA_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"
export GRANITE_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"
export SLACK_BOT_TOKEN="placeholder"
export SLACK_TEAM_ID="placeholder"

# Verify
echo "Hub: $HUB_CONTEXT"
echo "Cluster: $GPU_CLUSTER"
echo "Tokens: Set ✓"
```

### 2. Label GPU Cluster (Hub)

```bash
oc config use-context $HUB_CONTEXT

oc label managedcluster $GPU_CLUSTER \
  gpu-enabled=true \
  environment=production \
  vendor=OpenShift \
  --overwrite
```

### 3. Deploy Infrastructure Policies (Hub)

```bash
cd ~/Documents/claude_projects/llama-install/rhacm-deployment

# Deploy operators
oc apply -f policy-operators.yaml

# Deploy GPU config
oc apply -f policy-gpu-config.yaml

# Monitor (wait for "Compliant")
watch oc get policy -n llama-stack-policies
```

### 4. Deploy Secrets (Hub)

```bash
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
        type: Opaque
        stringData:
          AWS_ACCESS_KEY_ID: "$GRANITE_TOKEN"
          AWS_DEFAULT_REGION: us-east-1
          AWS_S3_BUCKET: placeholder
          AWS_S3_ENDPOINT: https://huggingface.co
          AWS_SECRET_ACCESS_KEY: "$GRANITE_TOKEN"
EOF
```

### 5. Deploy Granite Model (Hub)

```bash
oc apply -f manifestwork-granite.yaml

# Or inline:
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
          containers:
          - name: kserve-container
            image: quay.io/modh/vllm@sha256:4f550996130e7d16cacb24ca9a2865e7cf51eddaab014ceaf31a1ea6ef86d4ec
            command: [python, -m, vllm.entrypoints.openai.api_server]
            args: [--port=8080, --model=/mnt/models, --max-model-len, "4096", --gpu-memory-utilization, "0.9"]
            env:
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: slack-mcp-server-secrets
                  key: graniteToken
          supportedModelFormats:
          - name: vLLM
            autoSelect: true
      - apiVersion: serving.kserve.io/v1beta1
        kind: InferenceService
        metadata:
          name: granite32-8b
          namespace: llama-serve
          annotations:
            serving.knative.dev/progress-deadline: "1200s"
        spec:
          predictor:
            model:
              modelFormat:
                name: vLLM
              runtime: granite32-8b
              storageUri: oci://quay.io/redhat-ai-services/modelcar-catalog:granite-3.2-8b-instruct
              resources:
                requests:
                  nvidia.com/gpu: "1"
                limits:
                  nvidia.com/gpu: "1"
            tolerations:
            - key: nvidia.com/gpu
              operator: Equal
              value: "True"
EOF
```

### 6. Deploy LlamaStack via GitOps (Hub)

```bash
oc apply -f applicationset-llamastack.yaml
```

### 7. Verify (Managed Cluster)

```bash
# Switch to managed cluster
oc config use-context $GPU_CLUSTER

# Check pods (wait 5-10 min for model)
oc get pods -n llama-serve

# Get URLs
DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
echo "Streamlit: https://streamlit-llama-serve.$DOMAIN"
```

## Monitoring Commands

### From Hub Cluster

```bash
# Policy status
oc get policy -A

# ManifestWork status
oc get manifestwork -n $GPU_CLUSTER

# Applications
oc get application -n openshift-gitops | grep llamastack
```

### From Managed Cluster

```bash
# All resources
oc get all -n llama-serve

# GPU pods
oc get pods -n nvidia-gpu-operator

# Granite model
oc get inferenceservice -n llama-serve
```

## Troubleshooting One-Liners

```bash
# Policy not compliant
oc describe policy -n llama-stack-policies | grep -A 5 "Message"

# GPU not detected
oc get node -l node-role.kubernetes.io/worker-gpu -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu

# Model loading status
oc logs -n llama-serve $(oc get pod -n llama-serve -l serving.kserve.io/inferenceservice=granite32-8b -o name) -c kserve-container --tail=20

# ApplicationSet not syncing
oc get placement gpu-clusters -n llama-stack-apps -o jsonpath='{.status.decisions}'
```

## Timeline

| Step | Time | Status Check |
|------|------|-------------|
| Label cluster | 1 min | `oc get managedcluster $GPU_CLUSTER --show-labels` |
| Deploy policies | 2 min | `oc get policy -A` |
| Operators install | 15-20 min | `oc get csv -A` (on managed cluster) |
| GPU drivers | 10-15 min | `oc get pods -n nvidia-gpu-operator` |
| Deploy secrets | 1 min | `oc get manifestwork -n $GPU_CLUSTER` |
| Deploy model | 5-10 min | `oc get inferenceservice -n llama-serve` |
| Deploy apps | 5 min | `oc get application -n openshift-gitops` |
| **Total** | **40-55 min** | All green ✓ |

## URLs After Deployment

```bash
DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')

# User interfaces
echo "Streamlit:        https://streamlit-llama-serve.$DOMAIN"
echo "Lab Notebook:     https://lab-llama-serve.$DOMAIN"

# APIs  
echo "Granite Model:    https://granite32-8b-llama-serve.$DOMAIN/v1/models"
echo "LlamaStack API:   https://llamastack-server-llama-serve.$DOMAIN"

# Hub interfaces
echo "RHACM Console:    https://multicloud-console.apps.<hub-domain>"
echo "ArgoCD:           https://openshift-gitops-server-openshift-gitops.apps.<hub-domain>"
```

## Next Steps

- [ ] Set up monitoring dashboards
- [ ] Configure backup policies
- [ ] Deploy to additional clusters (just label them!)
- [ ] Customize models and configurations
- [ ] Implement External Secrets

---

**Full Documentation:** See [README.md](./README.md) for detailed explanations.
