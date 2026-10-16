#!/bin/bash

# LlamaStack URL Getter
# Usage: ./get-urls.sh <cluster-name>

GREEN='\033[0;32m'
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

# Check if cluster exists
if ! oc get managedcluster $CLUSTER &>/dev/null; then
    echo "Error: Cluster '$CLUSTER' not found"
    exit 1
fi

# Try to get cluster context
CLUSTER_CONTEXT=$(oc config get-contexts -o name | grep -i $CLUSTER | head -1)

if [ -z "$CLUSTER_CONTEXT" ]; then
    echo "Cannot access managed cluster directly."
    echo "Please switch to the managed cluster context first:"
    echo "  oc login <managed-cluster-api-url>"
    echo
    echo "Or use RHACM console to view routes"
    exit 1
fi

echo "=== LlamaStack Access URLs for $CLUSTER ==="
echo

# Get cluster domain
DOMAIN=$(oc --context=$CLUSTER_CONTEXT get ingress.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null)

if [ -z "$DOMAIN" ]; then
    echo "Error: Could not get cluster domain"
    exit 1
fi

echo -e "${GREEN}Cluster Domain:${NC} $DOMAIN"
echo

# Check if routes exist
ROUTES=$(oc --context=$CLUSTER_CONTEXT get routes -n llama-serve --no-headers 2>/dev/null)

if [ -z "$ROUTES" ]; then
    echo -e "${YELLOW}⚠ No routes found in llama-serve namespace${NC}"
    echo "  Deployment may still be in progress"
    exit 0
fi

# User Interfaces
echo "🖥️  User Interfaces"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

STREAMLIT_URL="https://streamlit-llama-serve.$DOMAIN"
LAB_URL="https://lab-llama-serve.$DOMAIN"

echo -e "${GREEN}Streamlit UI:${NC}"
echo "  $STREAMLIT_URL"
echo

# Check if lab route exists
if echo "$ROUTES" | grep -q "lab"; then
    echo -e "${GREEN}Jupyter Lab:${NC}"
    echo "  $LAB_URL"
    echo
fi

# APIs
echo "🔌 APIs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

GRANITE_URL="https://granite32-8b-llama-serve.$DOMAIN"
LLAMA_API_URL="https://llamastack-server-llama-serve.$DOMAIN"

echo -e "${GREEN}Granite Model API:${NC}"
echo "  $GRANITE_URL/v1/models"
echo "  $GRANITE_URL/v1/chat/completions"
echo

echo -e "${GREEN}LlamaStack API:${NC}"
echo "  $LLAMA_API_URL"
echo

# Test endpoints
echo "🧪 Test Commands"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "List available models:"
echo "  curl -k $GRANITE_URL/v1/models"
echo

echo "Test chat completion:"
cat <<'CMD'
  curl -k -X POST https://granite32-8b-llama-serve.$DOMAIN/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "granite32-8b",
      "messages": [{"role": "user", "content": "Hello!"}],
      "max_tokens": 100
    }'
CMD

echo
echo

# Health checks
echo "🏥 Health Checks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if InferenceService is ready
ISVC_READY=$(oc --context=$CLUSTER_CONTEXT get inferenceservice granite32-8b -n llama-serve -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

if [ "$ISVC_READY" == "True" ]; then
    echo -e "${GREEN}✓${NC} Granite Model: Ready"
else
    echo -e "${YELLOW}⚠${NC} Granite Model: Not ready (still loading)"
fi

# Check if routes are accessible
echo
echo "Checking route accessibility..."

check_route() {
    URL=$1
    NAME=$2
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" $URL 2>/dev/null)

    if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "401" ] || [ "$HTTP_CODE" == "404" ]; then
        echo -e "${GREEN}✓${NC} $NAME: Accessible (HTTP $HTTP_CODE)"
    else
        echo -e "${YELLOW}⚠${NC} $NAME: Not accessible (HTTP $HTTP_CODE)"
    fi
}

check_route "$STREAMLIT_URL" "Streamlit"
check_route "$GRANITE_URL/v1/models" "Granite API"
check_route "$LLAMA_API_URL" "LlamaStack API"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "💡 Quick links:"
echo "  - Open Streamlit: open $STREAMLIT_URL"
echo "  - RHACM Console: oc get route multicloud-console -n open-cluster-management -o jsonpath='{.spec.host}'"
echo "  - Check status: ./get-status.sh $CLUSTER"
