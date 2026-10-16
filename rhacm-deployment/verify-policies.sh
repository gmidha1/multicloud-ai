#!/bin/bash
# Verify RHACM Policies for LlamaStack Deployment
# This script checks the status of all policies and their components

set -e

POLICY_NAMESPACE="llama-stack-policies"
GPU_CLUSTER="${GPU_CLUSTER:-rosa-gpu1}"

echo "=========================================="
echo "LlamaStack RHACM Policy Verification"
echo "=========================================="
echo ""
echo "Hub Cluster Context: $(oc config current-context)"
echo "GPU Cluster: $GPU_CLUSTER"
echo ""

# Check if RHACM is installed
echo "=== Checking RHACM Installation ==="
if ! oc get multiclusterhub -n open-cluster-management &>/dev/null; then
  echo "❌ RHACM not installed on this cluster"
  exit 1
fi
echo "✅ RHACM is installed"
echo ""

# Check if policy namespace exists
echo "=== Checking Policy Namespace ==="
if ! oc get namespace $POLICY_NAMESPACE &>/dev/null; then
  echo "❌ Policy namespace '$POLICY_NAMESPACE' not found"
  echo "   Run: oc create namespace $POLICY_NAMESPACE"
  exit 1
fi
echo "✅ Policy namespace exists"
echo ""

# Check if managed cluster exists and is labeled
echo "=== Checking Managed Cluster ==="
if ! oc get managedcluster $GPU_CLUSTER &>/dev/null; then
  echo "❌ Managed cluster '$GPU_CLUSTER' not found"
  echo "   Available clusters:"
  oc get managedclusters -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].status
  exit 1
fi

GPU_LABEL=$(oc get managedcluster $GPU_CLUSTER -o jsonpath='{.metadata.labels.gpu-enabled}')
if [ "$GPU_LABEL" != "true" ]; then
  echo "⚠️  Cluster '$GPU_CLUSTER' not labeled with gpu-enabled=true"
  echo "   Run: oc label managedcluster $GPU_CLUSTER gpu-enabled=true"
else
  echo "✅ Managed cluster is properly labeled"
fi
echo ""

# Check if policies are deployed
echo "=== Checking Policy Deployment ==="
OPERATOR_POLICY=$(oc get policy llama-stack-operators -n $POLICY_NAMESPACE --no-headers 2>/dev/null | awk '{print $1}')
GPU_CONFIG_POLICY=$(oc get policy llama-stack-gpu-config -n $POLICY_NAMESPACE --no-headers 2>/dev/null | awk '{print $1}')

if [ -z "$OPERATOR_POLICY" ]; then
  echo "❌ llama-stack-operators policy not found"
  echo "   Run: oc apply -f rhacm-deployment/policy-operators.yaml"
else
  echo "✅ llama-stack-operators policy exists"
  OPERATOR_COMPLIANCE=$(oc get policy llama-stack-operators -n $POLICY_NAMESPACE -o jsonpath='{.status.compliant}')
  echo "   Compliance: $OPERATOR_COMPLIANCE"
fi

if [ -z "$GPU_CONFIG_POLICY" ]; then
  echo "❌ llama-stack-gpu-config policy not found"
  echo "   Run: oc apply -f rhacm-deployment/policy-gpu-config.yaml"
else
  echo "✅ llama-stack-gpu-config policy exists"
  GPU_COMPLIANCE=$(oc get policy llama-stack-gpu-config -n $POLICY_NAMESPACE -o jsonpath='{.status.compliant}')
  echo "   Compliance: $GPU_COMPLIANCE"
fi
echo ""

# Detailed compliance check
echo "=== Policy Compliance Details ==="
oc get policy -n $POLICY_NAMESPACE -o custom-columns=\
NAME:.metadata.name,\
COMPLIANCE:.status.compliant,\
REMEDIATION:.spec.remediationAction
echo ""

# Check placement binding
echo "=== Checking Placement ==="
oc get placementrule placement-gpu-clusters -n $POLICY_NAMESPACE -o yaml 2>/dev/null | grep -A5 "clusterSelector" || echo "⚠️  PlacementRule may need review"
echo ""

# Summary
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo ""

if [ "$OPERATOR_COMPLIANCE" == "Compliant" ] && [ "$GPU_COMPLIANCE" == "Compliant" ]; then
  echo "✅ All policies are compliant!"
  echo ""
  echo "1. Verify KServe is ready on managed cluster:"
  echo "   oc --context=$GPU_CLUSTER get crd servingruntimes.serving.kserve.io"
  echo ""
  echo "2. Run the Quick Readiness Check from README Step 9a"
  echo ""
  echo "3. Deploy secrets (README Part 5 Step 11)"
  echo ""
  echo "4. Deploy Granite model (README Part 6 Step 15)"
else
  echo "⚠️  Policies are not yet compliant. This may take 30-45 minutes."
  echo ""
  echo "Monitor progress with:"
  echo "  watch oc get policy -n $POLICY_NAMESPACE"
  echo ""
  echo "Check managed cluster operators:"
  echo "  oc --context=$GPU_CLUSTER get csv -A | grep -E 'gpu-operator|servicemesh|serverless|rhods'"
fi
echo ""
