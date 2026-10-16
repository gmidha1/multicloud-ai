#!/bin/bash

# LlamaStack Deployment Status Checker
# Usage: ./get-status.sh <cluster-name>

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$1" ]; then
    echo "Usage: $0 <cluster-name>"
    echo
    echo "Available clusters:"
    oc get managedclusters --no-headers | awk '{print "  - " $1}'
    exit 1
fi

CLUSTER=$1

echo "=== LlamaStack Deployment Status for $CLUSTER ==="
echo

# Check if cluster exists
if ! oc get managedcluster $CLUSTER &>/dev/null; then
    echo -e "${RED}Error: Cluster '$CLUSTER' not found${NC}"
    exit 1
fi

# Hub cluster status
echo "📊 Hub Cluster Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Policy compliance
echo
echo "Policies:"
POLICIES=$(oc get policy -n llama-stack-policies --no-headers 2>/dev/null | wc -l)
COMPLIANT=$(oc get policy -n llama-stack-policies --no-headers 2>/dev/null | grep -c "Compliant" || echo "0")

if [ "$POLICIES" -eq "$COMPLIANT" ] && [ "$POLICIES" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} All policies compliant ($COMPLIANT/$POLICIES)"
else
    echo -e "  ${YELLOW}⚠${NC} Policies: $COMPLIANT/$POLICIES compliant"
    oc get policy -n llama-stack-policies --no-headers | while read line; do
        STATUS=$(echo $line | awk '{print $3}')
        NAME=$(echo $line | awk '{print $1}')
        if [ "$STATUS" != "Compliant" ]; then
            echo -e "    ${RED}✗${NC} $NAME: $STATUS"
        fi
    done
fi

# ManifestWorks
echo
echo "ManifestWorks:"
MANIFESTWORKS=$(oc get manifestwork -n $CLUSTER --no-headers 2>/dev/null)
if [ -z "$MANIFESTWORKS" ]; then
    echo -e "  ${YELLOW}⚠${NC} No ManifestWorks found"
else
    echo "$MANIFESTWORKS" | while read line; do
        NAME=$(echo $line | awk '{print $1}')
        APPLIED=$(oc get manifestwork $NAME -n $CLUSTER -o jsonpath='{.status.conditions[?(@.type=="Applied")].status}' 2>/dev/null)
        if [ "$APPLIED" == "True" ]; then
            echo -e "  ${GREEN}✓${NC} $NAME: Applied"
        else
            echo -e "  ${YELLOW}⚠${NC} $NAME: Not applied"
        fi
    done
fi

# Applications
echo
echo "Applications:"
APPS=$(oc get application -n openshift-gitops --no-headers 2>/dev/null | grep llamastack | grep $CLUSTER)
if [ -z "$APPS" ]; then
    echo -e "  ${YELLOW}⚠${NC} No applications found (ApplicationSet may not be deployed)"
else
    echo "$APPS" | while read line; do
        NAME=$(echo $line | awk '{print $1}')
        SYNC=$(echo $line | awk '{print $2}')
        HEALTH=$(echo $line | awk '{print $3}')

        if [ "$SYNC" == "Synced" ] && [ "$HEALTH" == "Healthy" ]; then
            echo -e "  ${GREEN}✓${NC} $NAME: $SYNC, $HEALTH"
        else
            echo -e "  ${YELLOW}⚠${NC} $NAME: $SYNC, $HEALTH"
        fi
    done
fi

# Check if we can access managed cluster
echo
echo "📊 Managed Cluster Status ($CLUSTER)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Try to get cluster context
CLUSTER_CONTEXT=$(oc config get-contexts -o name | grep -i $CLUSTER | head -1)

if [ -z "$CLUSTER_CONTEXT" ]; then
    echo -e "${YELLOW}⚠ Cannot access managed cluster directly${NC}"
    echo "  Use RHACM console or import kubeconfig to check managed cluster"
    echo
    echo "  To check from RHACM:"
    echo "    oc get manifestwork -n $CLUSTER -o yaml"
    exit 0
fi

echo "Using context: $CLUSTER_CONTEXT"
echo

# GPU Nodes
echo "GPU Nodes:"
GPU_NODES=$(oc --context=$CLUSTER_CONTEXT get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null)
if [ -z "$GPU_NODES" ]; then
    echo -e "  ${YELLOW}⚠${NC} No GPU nodes labeled yet"
else
    echo "$GPU_NODES" | while read line; do
        NODE=$(echo $line | awk '{print $1}')
        GPU=$(oc --context=$CLUSTER_CONTEXT get node $NODE -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null)
        if [ -n "$GPU" ] && [ "$GPU" != "0" ]; then
            echo -e "  ${GREEN}✓${NC} $NODE: $GPU GPU(s)"
        else
            echo -e "  ${YELLOW}⚠${NC} $NODE: No GPU detected (driver may be installing)"
        fi
    done
fi

# Operators
echo
echo "Operators:"
check_operator() {
    NAMESPACE=$1
    PATTERN=$2
    CSV=$(oc --context=$CLUSTER_CONTEXT get csv -n $NAMESPACE --no-headers 2>/dev/null | grep $PATTERN | head -1)
    if [ -n "$CSV" ]; then
        PHASE=$(echo $CSV | awk '{print $NF}')
        if [ "$PHASE" == "Succeeded" ]; then
            echo -e "  ${GREEN}✓${NC} $PATTERN: $PHASE"
        else
            echo -e "  ${YELLOW}⚠${NC} $PATTERN: $PHASE"
        fi
    else
        echo -e "  ${RED}✗${NC} $PATTERN: Not found"
    fi
}

check_operator "nvidia-gpu-operator" "gpu-operator"
check_operator "openshift-nfd" "nfd"
check_operator "redhat-ods-operator" "rhods-operator"

# LlamaStack namespace
echo
echo "LlamaStack Pods (llama-serve namespace):"
PODS=$(oc --context=$CLUSTER_CONTEXT get pods -n llama-serve --no-headers 2>/dev/null)
if [ -z "$PODS" ]; then
    echo -e "  ${YELLOW}⚠${NC} No pods found (deployment may not have started)"
else
    echo "$PODS" | while read line; do
        NAME=$(echo $line | awk '{print $1}')
        READY=$(echo $line | awk '{print $2}')
        STATUS=$(echo $line | awk '{print $3}')

        if [ "$STATUS" == "Running" ] && [[ "$READY" == *"/"* ]]; then
            CURRENT=$(echo $READY | cut -d'/' -f1)
            TOTAL=$(echo $READY | cut -d'/' -f2)
            if [ "$CURRENT" == "$TOTAL" ]; then
                echo -e "  ${GREEN}✓${NC} $NAME: $READY $STATUS"
            else
                echo -e "  ${YELLOW}⚠${NC} $NAME: $READY $STATUS"
            fi
        elif [ "$STATUS" == "Completed" ]; then
            echo -e "  ${GREEN}✓${NC} $NAME: $STATUS"
        else
            echo -e "  ${YELLOW}⚠${NC} $NAME: $READY $STATUS"
        fi
    done
fi

# InferenceService
echo
echo "Granite Model (InferenceService):"
ISVC=$(oc --context=$CLUSTER_CONTEXT get inferenceservice granite32-8b -n llama-serve --no-headers 2>/dev/null)
if [ -z "$ISVC" ]; then
    echo -e "  ${YELLOW}⚠${NC} InferenceService not found"
else
    READY=$(oc --context=$CLUSTER_CONTEXT get inferenceservice granite32-8b -n llama-serve -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    URL=$(oc --context=$CLUSTER_CONTEXT get inferenceservice granite32-8b -n llama-serve -o jsonpath='{.status.url}' 2>/dev/null)

    if [ "$READY" == "True" ]; then
        echo -e "  ${GREEN}✓${NC} granite32-8b: Ready"
        echo -e "     URL: $URL"
    else
        echo -e "  ${YELLOW}⚠${NC} granite32-8b: Not ready (model may be loading)"
        echo -e "     This can take 5-10 minutes for model download"
    fi
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "💡 Next steps:"
echo "  - Monitor policy compliance: oc get policy -n llama-stack-policies"
echo "  - Check detailed logs: oc --context=$CLUSTER_CONTEXT logs -n llama-serve <pod-name>"
echo "  - Get access URLs: ./get-urls.sh $CLUSTER"
