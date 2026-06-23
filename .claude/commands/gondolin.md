# Gondolin — Hide a Managed Cluster from Placement

You are executing the **Gondolin** skill. This hides a managed cluster from all Placement decisions while protecting its existing ManifestWorks from deletion. Think of it as making the cluster a Hidden City — invisible to scheduling, but everything running on it stays alive.

## Arguments

`$ARGUMENTS` should be parsed as: `<cluster-name> <hub-kubeconfig-path>`

- **cluster-name**: The name of the ManagedCluster to hide
- **hub-kubeconfig-path**: Path to the hub cluster kubeconfig

If arguments are missing, ask the user for them.

## Procedure

Run these steps in order. Stop and report if any step fails.

### Step 1 — Validate the cluster

```bash
KUBECONFIG=<hub-kubeconfig> kubectl get managedcluster <cluster-name> -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}'
```

Confirm the cluster exists. If it already has a `gondolin=true:NoSelect` taint, tell the user the cluster is already hidden and stop.

Check for the existing taint:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get managedcluster <cluster-name> -o jsonpath='{.spec.taints[?(@.key=="gondolin")]}'
```

### Step 2 — Snapshot existing ManifestWorks

List all ManifestWorks in the cluster's namespace on the hub:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get manifestworks -n <cluster-name>
```

Report what will be protected. If there are no ManifestWorks, warn the user there's nothing to protect but proceed anyway (the taint still hides the cluster).

### Step 3 — Create the ValidatingAdmissionPolicy

Apply this policy to block all ManifestWork deletions in the cluster's namespace:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: gondolin-<cluster-name>
  labels:
    gondolin.io/protected-cluster: "<cluster-name>"
spec:
  failurePolicy: Fail
  matchConstraints:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: "<cluster-name>"
    resourceRules:
    - apiGroups: ["work.open-cluster-management.io"]
      apiVersions: ["v1"]
      operations: ["DELETE"]
      resources: ["manifestworks"]
  validations:
  - expression: "false"
    message: "Gondolin: ManifestWork deletion is blocked — cluster <cluster-name> is hidden"
EOF
```

Replace `<cluster-name>` with the actual cluster name in ALL places.

### Step 4 — Create the ValidatingAdmissionPolicyBinding

```bash
KUBECONFIG=<hub-kubeconfig> kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: gondolin-<cluster-name>
  labels:
    gondolin.io/protected-cluster: "<cluster-name>"
spec:
  policyName: gondolin-<cluster-name>
  validationActions:
  - Deny
EOF
```

Replace `<cluster-name>` with the actual cluster name.

### Step 5 — Verify the VAP is active before proceeding

**CRITICAL:** The ValidatingAdmissionPolicy takes a few seconds to propagate. You MUST confirm it is blocking deletions before adding the taint, otherwise the controller may delete ManifestWorks in the gap.

Pick any existing ManifestWork from the cluster namespace and attempt a server-side dry-run delete:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl delete manifestwork <any-manifestwork-name> -n <cluster-name> --dry-run=server
```

If the VAP is active, this will return an error containing `denied request: Gondolin`. If the dry-run succeeds (no error), wait 3 seconds and retry. Repeat up to 10 times. Do NOT proceed to step 6 until the dry-run delete is denied.

### Step 6 — Add the NoSelect taint

Only run this AFTER step 5 confirms the VAP is blocking deletions:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl patch managedcluster <cluster-name> --type=merge -p '{"spec":{"taints":[{"key":"gondolin","value":"true","effect":"NoSelect"}]}}'
```

### Step 7 — Verify

1. Confirm placement no longer selects the cluster — check all PlacementDecisions in all namespaces for this cluster:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get placementdecisions -A -o json | jq -r '.items[] | select(.status.decisions[]?.clusterName == "<cluster-name>") | .metadata.namespace + "/" + .metadata.name'
```
If nothing is returned, the cluster is hidden from all placements. If results appear, wait a few seconds and re-check (the placement controller may need a moment).

2. Confirm ManifestWorks still exist:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get manifestworks -n <cluster-name>
```

### Step 8 — Report

Tell the user:
- The cluster is now hidden from all Placements (gondolin applied)
- How many ManifestWorks are protected
- The ValidatingAdmissionPolicy `gondolin-<cluster-name>` is blocking ManifestWork deletion
- To reverse this, run `/fall-of-gondolin <cluster-name> <hub-kubeconfig>`
