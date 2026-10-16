# RHACM Deployment Files Guide

## Quick Decision Tree

**Start here:**

```
Do you want automated deployment?
├─ YES → Use deploy.sh (recommended)
│   └─ Just run: ./deploy.sh
│
└─ NO (manual control) → Follow manual steps below
    ├─ Step 1: policy-operators.yaml
    ├─ Step 2: policy-gpu-config.yaml
    ├─ Step 3: Create secrets (inline in QUICK-START.md)
    ├─ Step 4: manifestwork-granite.yaml
    └─ Step 5: applicationset-llamastack.yaml
```

---

## 📁 File Descriptions

### 1. **deploy.sh** ⭐ START HERE
**Type:** Automated deployment script  
**Use when:** You want the easiest deployment experience

**What it does:**
1. Prompts you for cluster name and tokens
2. Labels your GPU cluster automatically
3. Deploys all policies (operators + GPU config)
4. Creates secrets via ManifestWork
5. Deploys Granite model
6. Deploys ApplicationSet

**How to use:**
```bash
# Make sure you're on the hub cluster
oc config use-context <hub-cluster>

# Run the script
./deploy.sh

# It will prompt you for:
# - Managed cluster name
# - LLAMA_TOKEN
# - GRANITE_TOKEN
# - SLACK_BOT_TOKEN (optional)
# - SLACK_TEAM_ID (optional)
```

**Or set environment variables first:**
```bash
export GPU_CLUSTER="my-rosa-cluster"
export LLAMA_TOKEN="hf_xxxxx"
export GRANITE_TOKEN="hf_xxxxx"
./deploy.sh
```

---

### 2. **QUICK-START.md** 📖 QUICK REFERENCE
**Type:** Documentation  
**Use when:** You want copy-paste commands for manual deployment

**What it contains:**
- Quick decision tree
- Copy-paste ready commands
- Monitoring commands
- Troubleshooting one-liners
- Timeline expectations

**How to use:**
```bash
# Read it
cat QUICK-START.md

# Or open in your editor
code QUICK-START.md
```

**Best for:** Quick reference while deploying manually

---

### 3. **README.md** 📘 DETAILED GUIDE
**Type:** Complete documentation  
**Use when:** You want to understand every step in detail

**What it contains:**
- Complete step-by-step guide (21 steps)
- Detailed explanations
- Troubleshooting section
- Day 2 operations
- Multi-cluster deployment guide

**How to use:**
```bash
# Read it
less README.md

# Follow the numbered steps if doing manual deployment
```

**Best for:** Understanding the full deployment process

---

### 4. **policy-operators.yaml** 🔧 INFRASTRUCTURE POLICY
**Type:** RHACM Policy  
**Use when:** Manually deploying infrastructure

**What it deploys:**
- GPU Operator (NVIDIA)
- NFD Operator (Node Feature Discovery)
- RHOAI Operator

**How to use:**
```bash
# Deploy from hub cluster
oc apply -f policy-operators.yaml

# Monitor
watch oc get policy -n llama-stack-policies
```

**⏱️ Takes:** 15-20 minutes for operators to install

---

### 5. **policy-gpu-config.yaml** 🎮 GPU CONFIGURATION POLICY
**Type:** RHACM Policy  
**Use when:** Manually configuring GPU infrastructure

**What it deploys:**
- NFD Instance
- GPU ClusterPolicy (drivers)
- DataScienceCluster

**How to use:**
```bash
# Deploy after policy-operators.yaml is compliant
oc apply -f policy-gpu-config.yaml

# Monitor
oc get policy -n llama-stack-policies
```

**⏱️ Takes:** 10-15 minutes for GPU drivers to install

---

### 6. **manifestwork-granite.yaml** 🤖 GRANITE MODEL
**Type:** RHACM ManifestWork  
**Use when:** Manually deploying the Granite model

**What it deploys:**
- ServingRuntime (vLLM configuration)
- InferenceService (Granite 3.2 8B model)

**How to use:**
```bash
# FIRST: Edit the file to replace cluster name
sed -i '' 's/REPLACE_WITH_CLUSTER_NAME/my-cluster-name/g' manifestwork-granite.yaml

# Deploy from hub cluster
oc apply -f manifestwork-granite.yaml

# Monitor
oc get manifestwork -n <cluster-name>
```

**⏱️ Takes:** 5-10 minutes for model download and loading

---

### 7. **applicationset-llamastack.yaml** 🚀 LLAMASTACK APP
**Type:** ArgoCD ApplicationSet  
**Use when:** Deploying LlamaStack components via GitOps

**What it deploys:**
- LlamaStack server
- Streamlit UI
- MCP servers (OpenShift, Slack)
- Jupyter Lab

**How to use:**
```bash
# Deploy from hub cluster
oc apply -f applicationset-llamastack.yaml

# Monitor
oc get application -n openshift-gitops | grep llamastack
```

**⏱️ Takes:** 5 minutes to sync and deploy

---

### 8. **get-status.sh** 📊 STATUS CHECKER
**Type:** Helper script  
**Use when:** Checking deployment progress

**What it shows:**
- Policy compliance status
- ManifestWork status
- Application sync status
- Pod status on managed cluster
- GPU availability
- Operator status
- Granite model readiness

**How to use:**
```bash
./get-status.sh <cluster-name>

# Example:
./get-status.sh rosa-gpu-prod
```

**Output:**
```
=== LlamaStack Deployment Status for rosa-gpu-prod ===

📊 Hub Cluster Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Policies:
  ✓ All policies compliant (2/2)

ManifestWorks:
  ✓ llamastack-secrets: Applied
  ✓ llamastack-granite-model: Applied

📊 Managed Cluster Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GPU Nodes:
  ✓ ip-10-0-0-21.ec2.internal: 1 GPU(s)

Operators:
  ✓ gpu-operator: Succeeded
  ✓ nfd: Succeeded
  ✓ rhods-operator: Succeeded

LlamaStack Pods:
  ✓ granite32-8b-predictor-xxxxx: 4/4 Running
  ✓ llamastack-deployment-xxxxx: 1/1 Running
  ...
```

---

### 9. **get-urls.sh** 🔗 URL GETTER
**Type:** Helper script  
**Use when:** Getting access URLs after deployment

**What it shows:**
- Streamlit UI URL
- Granite model API URL
- LlamaStack API URL
- Test commands
- Health check results

**How to use:**
```bash
./get-urls.sh <cluster-name>

# Example:
./get-urls.sh rosa-gpu-prod
```

**Output:**
```
=== LlamaStack Access URLs for rosa-gpu-prod ===

Cluster Domain: apps.rosa.example.com

🖥️  User Interfaces
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Streamlit UI:
  https://streamlit-llama-serve.apps.rosa.example.com

🔌 APIs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Granite Model API:
  https://granite32-8b-llama-serve.apps.rosa.example.com/v1/models
  https://granite32-8b-llama-serve.apps.rosa.example.com/v1/chat/completions

🧪 Test Commands
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
List available models:
  curl -k https://granite32-8b-llama-serve.apps.rosa.example.com/v1/models
```

---

## 🚀 Recommended Workflows

### Workflow A: Quickest Start (Recommended)

```bash
# 1. Ensure you're on hub cluster
oc config use-context <hub-cluster>

# 2. Run automated deployment
cd ~/Documents/claude_projects/llama-install/rhacm-deployment
./deploy.sh

# 3. Monitor progress (run in another terminal)
watch ./get-status.sh <cluster-name>

# 4. Get URLs when ready (after ~50 min)
./get-urls.sh <cluster-name>
```

**Time:** 5 min setup + 45 min automated

---

### Workflow B: Manual Step-by-Step

```bash
# 1. Read the quick start guide
cat QUICK-START.md

# 2. Set environment variables
export GPU_CLUSTER="my-cluster"
export LLAMA_TOKEN="hf_xxxxx"
export GRANITE_TOKEN="hf_xxxxx"

# 3. Label cluster
oc label managedcluster $GPU_CLUSTER gpu-enabled=true

# 4. Deploy policies
oc apply -f policy-operators.yaml
oc apply -f policy-gpu-config.yaml

# 5. Wait for policies to be compliant (~30 min)
watch oc get policy -n llama-stack-policies

# 6. Deploy secrets (copy from QUICK-START.md, Step 4)

# 7. Edit and deploy Granite model
sed -i '' "s/REPLACE_WITH_CLUSTER_NAME/$GPU_CLUSTER/g" manifestwork-granite.yaml
oc apply -f manifestwork-granite.yaml

# 8. Deploy ApplicationSet
oc apply -f applicationset-llamastack.yaml

# 9. Monitor and get URLs
./get-status.sh $GPU_CLUSTER
./get-urls.sh $GPU_CLUSTER
```

**Time:** Full manual control, ~50 min total

---

### Workflow C: Understanding Every Detail

```bash
# 1. Read full documentation
less README.md

# 2. Follow all 21 steps in README.md

# 3. Use helper scripts for monitoring
./get-status.sh <cluster-name>
./get-urls.sh <cluster-name>
```

**Time:** Educational, ~60 min with reading

---

## 📊 File Usage Matrix

| File | When to Use | Required? | Order |
|------|-------------|-----------|-------|
| deploy.sh | Automated deployment | No (but recommended) | 1st |
| QUICK-START.md | Quick reference | No | Read anytime |
| README.md | Full understanding | No | Read for details |
| policy-operators.yaml | Manual infrastructure | Yes | 2nd |
| policy-gpu-config.yaml | Manual GPU setup | Yes | 3rd |
| manifestwork-granite.yaml | Manual model deploy | Yes | 4th |
| applicationset-llamastack.yaml | GitOps app deploy | Optional | 5th |
| get-status.sh | Check progress | No (helper) | Anytime |
| get-urls.sh | Get access URLs | No (helper) | After deploy |

---

## 🎓 Which File Should YOU Use?

### **If you want:**

**"Just make it work, quickly"**
→ Use `deploy.sh`

**"I want to understand what's happening"**
→ Read `README.md`, then use `deploy.sh` or manual steps

**"Quick copy-paste commands"**
→ Use `QUICK-START.md`

**"Step-by-step manual control"**
→ Follow `README.md` + use individual YAML files

**"Check if it's working"**
→ Use `get-status.sh`

**"Get the URLs to access"**
→ Use `get-urls.sh`

---

## ⚠️ Important Notes

1. **Always start from the hub cluster context**
   ```bash
   oc config use-context <hub-cluster>
   ```

2. **Set your tokens before starting**
   ```bash
   export LLAMA_TOKEN="hf_xxxxx"
   export GRANITE_TOKEN="hf_xxxxx"
   ```

3. **Label your GPU cluster first**
   ```bash
   oc label managedcluster <cluster-name> gpu-enabled=true
   ```

4. **Wait for each phase to complete**
   - Operators: 15-20 min
   - GPU drivers: 10-15 min
   - Model loading: 5-10 min

5. **Use helper scripts to monitor**
   ```bash
   ./get-status.sh <cluster-name>
   ```

---

## 🆘 Getting Help

**If deployment fails:**
1. Run `./get-status.sh <cluster-name>` to see what failed
2. Check the README.md "Troubleshooting" section
3. Check policy compliance: `oc get policy -A`
4. Check ManifestWork status: `oc get manifestwork -n <cluster>`

**If you're stuck:**
1. Start with QUICK-START.md
2. Read the relevant section in README.md
3. Use helper scripts to diagnose

---

## 📞 Quick Reference

```bash
# Automated deployment
./deploy.sh

# Check status
./get-status.sh <cluster-name>

# Get URLs
./get-urls.sh <cluster-name>

# Manual policies
oc apply -f policy-operators.yaml
oc apply -f policy-gpu-config.yaml

# Manual model
oc apply -f manifestwork-granite.yaml

# Manual app
oc apply -f applicationset-llamastack.yaml
```

**Remember:** The easiest path is `./deploy.sh` ⭐
