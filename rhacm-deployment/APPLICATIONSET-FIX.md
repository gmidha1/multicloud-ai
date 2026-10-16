# ApplicationSet Fix Guide

## Problem Summary

The llamastack-deployment ApplicationSet was not creating Applications for managed clusters due to missing RBAC permissions, incorrect ConfigMap format, and missing ManagedClusterSetBinding.

## Symptoms

```bash
oc get applications -n openshift-gitops
# No resources found

oc get applicationset llamastack-deployment -n openshift-gitops -o jsonpath='{.status.conditions}' | jq
# Errors:
# - "there is a problem with the apiVersion, kind or resourceName provided"
# - "failed to get dynamic resources: PlacementDecision...is forbidden"
```

## Root Causes

1. **Missing ManagedClusterSetBinding** - openshift-gitops namespace cannot access managed clusters
2. **Incorrect ConfigMap format** - acm-placement ConfigMap missing required fields for ClusterDecisionResource generator
3. **Missing RBAC permissions** - ApplicationSet controller cannot read PlacementDecisions
4. **Wrong ClusterSet** - Placement referenced "global" but clusters are in "default"

## Complete Fix (Run on Hub Cluster)

```bash
# Fix 1: Create ManagedClusterSetBinding
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: openshift-gitops
spec:
  clusterSet: default
EOF

# Fix 2: Create RBAC permissions
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-placementdecision-reader
rules:
- apiGroups:
  - cluster.open-cluster-management.io
  resources:
  - placementdecisions
  - placementdecisions/status
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-placementdecision-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-placementdecision-reader
subjects:
- kind: ServiceAccount
  name: openshift-gitops-applicationset-controller
  namespace: openshift-gitops
EOF

# Fix 3: Update ConfigMap with correct format
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: acm-placement
  namespace: openshift-gitops
data:
  apiVersion: cluster.open-cluster-management.io/v1beta1
  kind: PlacementDecision
  resource: placementdecisions
  statusListKey: decisions
  matchKey: clusterName
EOF

# Fix 4: Update Placement to use correct clusterset
cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: gpu-clusters
  namespace: openshift-gitops
spec:
  clusterSets:
    - default
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

# Fix 5: Restart ApplicationSet controller
oc delete pod -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-applicationset-controller

# Wait for restart and reconciliation
sleep 30
```

## Verification

```bash
# 1. Verify ManagedClusterSetBinding
oc get managedclustersetbinding -n openshift-gitops
# Should show: default binding

# 2. Verify RBAC permissions
oc auth can-i list placementdecisions.cluster.open-cluster-management.io \
  -n openshift-gitops \
  --as system:serviceaccount:openshift-gitops:openshift-gitops-applicationset-controller
# Should return: yes

# 3. Verify Placement is satisfied
oc get placement gpu-clusters -n openshift-gitops
# Should show: SUCCEEDED=True, SELECTEDCLUSTERS > 0

# 4. Verify PlacementDecisions exist
oc get placementdecision -n openshift-gitops -l cluster.open-cluster-management.io/placement=gpu-clusters
# Should list decisions with cluster names

# 5. Check ApplicationSet status
oc get applicationset llamastack-deployment -n openshift-gitops -o jsonpath='{.status.conditions}' | jq
# Should NOT show forbidden or apiVersion errors

# 6. Verify Applications are created (may take 3-5 minutes)
watch oc get applications -n openshift-gitops
# Should show: llamastack-<cluster-name> applications
```

## If Applications Still Don't Appear

```bash
# Delete and recreate ApplicationSet to force reconciliation
oc delete applicationset llamastack-deployment -n openshift-gitops
oc apply -f applicationset-llamastack.yaml

# Monitor creation
watch oc get applications -n openshift-gitops
```

## Files Updated

1. **README.md** - Added Step 13a with prerequisites, updated ConfigMap format in Step 14, added troubleshooting section
2. **applicationset-llamastack.yaml** - Fixed ConfigMap format, updated Placement clusterSets

## Prevention for Future Deployments

Always run these steps BEFORE creating the ApplicationSet:

1. Create ManagedClusterSetBinding
2. Create RBAC ClusterRole and ClusterRoleBinding
3. Verify Placement creates PlacementDecisions
4. Then create ApplicationSet

See updated Step 13a in README.md for the complete sequence.
