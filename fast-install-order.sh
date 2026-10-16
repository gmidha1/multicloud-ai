#!/bin/bash
# Fast RHOAI Installation Script
# Installs dependencies in parallel, then RHOAI

set -e

echo "=== Phase 1: Install all operators in parallel ==="

# Install GPU operator
oc apply -f - <<EOF
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

# Install Service Mesh, Serverless, Authorino in one go
oc apply -f - <<EOF
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
---
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
---
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
spec: {}  # AllNamespaces mode - critical!
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
---
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

echo "=== Phase 2: Wait for operators to be ready ==="

# Wait for all operators in parallel (with timeout)
timeout 600 bash -c 'until oc get csv -n nvidia-gpu-operator -o jsonpath="{.items[?(@.metadata.name=~\"gpu-operator.*\")].status.phase}" | grep -q Succeeded; do sleep 5; done' &
timeout 600 bash -c 'until oc get csv -n openshift-operators -o jsonpath="{.items[?(@.metadata.name=~\"servicemesh.*\")].status.phase}" | grep -q Succeeded; do sleep 5; done' &
timeout 600 bash -c 'until oc get csv -n openshift-operators -o jsonpath="{.items[?(@.metadata.name=~\"serverless.*\")].status.phase}" | grep -q Succeeded; do sleep 5; done' &
timeout 600 bash -c 'until oc get csv -n redhat-authorization-provider -o jsonpath="{.items[?(@.metadata.name=~\"authorino.*\")].status.phase}" | grep -q Succeeded; do sleep 5; done' &
timeout 600 bash -c 'until oc get deployment openshift-gitops-server -n openshift-gitops --ignore-not-found -o jsonpath="{.status.availableReplicas}" | grep -q 1; do sleep 5; done' &

wait
echo "All operators ready!"

echo "=== Phase 3: Install RHOAI with latest version ==="

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  targetNamespaces:
  - redhat-ods-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "=== Phase 4: Wait for RHOAI operator ==="
timeout 600 bash -c 'until oc get csv -n redhat-ods-operator -o jsonpath="{.items[?(@.metadata.name=~\"rhods.*\")].status.phase}" | grep -q Succeeded; do sleep 5; done'

echo "=== Phase 5: Wait for DSCInitialization ==="
timeout 600 bash -c 'until oc get dscinitialization default-dsci -o jsonpath="{.status.phase}" 2>/dev/null | grep -q Ready; do sleep 10; done'

echo "✅ RHOAI installation complete!"
echo "Total time: Much faster than sequential installation"
