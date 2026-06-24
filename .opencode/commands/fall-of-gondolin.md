---
description: "Reverse gondolin on a managed cluster, making it visible to Placements again"
---

# Fall of Gondolin — Reverse Gondolin on a Managed Cluster

You are executing the **Fall of Gondolin** skill. This reverses the gondolin protection on a managed cluster, making it visible to Placements again while ensuring workloads are never interrupted.

Named after *The Fall of Gondolin* by J.R.R. Tolkien — the story of how the Hidden City was revealed and its enchantments broken.

## Arguments

`$ARGUMENTS` should be parsed as: `<cluster-name> <hub-kubeconfig-path>`

- **cluster-name**: The name of the ManagedCluster to unhide
- **hub-kubeconfig-path**: Path to the hub cluster kubeconfig

If arguments are missing, ask the user for them.

## Procedure

**ORDERING IS CRITICAL.** The taint must be removed BEFORE the admission policy so that placement re-selects the cluster and the controller re-adopts its ManifestWorks before we remove the deletion protection. Follow the steps exactly in order.

### Step 1 — Validate the cluster is hidden

Check the cluster has the gondolin taint:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get managedcluster <cluster-name> -o jsonpath='{.spec.taints[?(@.key=="gondolin")]}'
```

Check the ValidatingAdmissionPolicy exists:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get validatingadmissionpolicy gondolin-<cluster-name>
```

If neither exists, tell the user the cluster is not hidden (gondolin is not applied) and stop.

### Step 2 — Remove the NoSelect taint

Remove the gondolin taint from the ManagedCluster. Use a JSON patch to remove only the gondolin taint while preserving any other taints:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl get managedcluster <cluster-name> -o jsonpath='{.spec.taints}'
```

Then build a patch that includes all existing taints EXCEPT the gondolin one and apply it:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl patch managedcluster <cluster-name> --type=merge -p '{"spec":{"taints":[<remaining-taints>]}}'
```

If gondolin was the only taint, set taints to an empty array:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl patch managedcluster <cluster-name> --type=merge -p '{"spec":{"taints":[]}}'
```

### Step 3 — Wait for Placement to re-select the cluster

Poll PlacementDecisions until the cluster appears in at least one decision. Check every 5 seconds, up to 60 seconds:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl get placementdecisions -A -o json | jq -r '.items[] | select(.status.decisions[]?.clusterName == "<cluster-name>") | .metadata.namespace + "/" + .metadata.name'
```

If after 60 seconds the cluster is not in any PlacementDecision, warn the user. This could mean no Placement currently targets this cluster (which is fine — it just means there are no placement-driven ManifestWorks to worry about). Proceed to step 5.

### Step 4 — Wait for controller to reconcile

The controller needs to recognize the cluster is back in placement and stop trying to delete its ManifestWorks. Wait 10 seconds after placement re-selects the cluster, then verify ManifestWorks are in a good state:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl get manifestworks -n <cluster-name>
```

Check that ManifestWorkReplicaSets referencing placements that include this cluster show healthy status:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get manifestworkreplicasets -A
```

### Step 5 — Remove the ValidatingAdmissionPolicy and Binding

Now that the cluster is back in placement and the controller is no longer trying to delete ManifestWorks, it is safe to remove the deletion protection:

```bash
KUBECONFIG=<hub-kubeconfig> kubectl delete validatingadmissionpolicybinding gondolin-<cluster-name>
KUBECONFIG=<hub-kubeconfig> kubectl delete validatingadmissionpolicy gondolin-<cluster-name>
```

### Step 6 — Verify

1. Confirm the cluster has no gondolin taint:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get managedcluster <cluster-name> -o jsonpath='{.spec.taints}'
```

2. Confirm the cluster is in PlacementDecisions:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get placementdecisions -A -o json | jq -r '.items[] | select(.status.decisions[]?.clusterName == "<cluster-name>") | .metadata.namespace + "/" + .metadata.name'
```

3. Confirm ManifestWorks are intact:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get manifestworks -n <cluster-name>
```

4. Confirm no gondolin admission policy remains:
```bash
KUBECONFIG=<hub-kubeconfig> kubectl get validatingadmissionpolicy gondolin-<cluster-name> 2>&1
```

### Step 7 — Report

Tell the user:
- Gondolin has been lifted — the cluster is visible to Placements again
- ManifestWorks were preserved throughout the transition (no workload interruption)
- The ValidatingAdmissionPolicy has been removed
