# Gondolin

> *"Gondolin was the greatest and most glorious Elven city of the First Age. Also known as the Hidden City, it was secretly founded by the Elven-king Turgon inside the protective Encircling Mountains in Beleriand."*

## What is this?

Gondolin brings the concept of the Hidden City to Open Cluster Management. It provides Claude Code skills that allow you to **hide a managed cluster from all Placement decisions** while **protecting its existing ManifestWork workloads from deletion** — the cluster becomes invisible to scheduling, but everything running on it stays alive.

This is currently a **skill-based demo** of the behavior. If proven useful, it could be baked into OCM/ACM as a first-class feature.

## How it works

Gondolin uses two Kubernetes-native mechanisms (no code changes required):

1. **ManagedCluster Taints** — A `gondolin=true:NoSelect` taint is added to the cluster, causing all Placements to stop selecting it.
2. **ValidatingAdmissionPolicy** — A policy is created on the hub that blocks all `DELETE` operations on ManifestWorks in the cluster's namespace, preventing the ManifestWorkReplicaSet controller from removing workloads.

Together, these ensure the cluster is hidden from new scheduling while all existing workloads remain protected and running.

## Business use cases

- **Maintenance windows** — Hide a cluster from scheduling during planned maintenance without disrupting running workloads. New work goes elsewhere; existing work keeps running.
- **Controlled draining** — Stop new workloads from being placed on a cluster while preserving what's already there. Operators can then selectively migrate workloads at their own pace.
- **Emergency isolation** — Quickly pull a cluster out of rotation (e.g., due to a security concern or resource pressure) without causing workload disruption across the fleet.
- **Blue-green cluster transitions** — Temporarily hide a cluster while its replacement comes online, then either restore it or fully decommission it.

## Skills

### `/gondolin <cluster-name> <hub-kubeconfig-path>`

Hides a managed cluster from all Placements and protects its ManifestWorks from deletion.

**What it does:**
1. Creates a `ValidatingAdmissionPolicy` that blocks ManifestWork deletion in the cluster's hub namespace
2. Verifies the policy is active (dry-run delete must be denied before proceeding)
3. Adds a `gondolin=true:NoSelect` taint to the ManagedCluster
4. Verifies the cluster is no longer in any PlacementDecision and ManifestWorks are intact

**Example:**
```
/gondolin managed1 /tmp/hub-kubeconfig
```

### `/fall-of-gondolin <cluster-name> <hub-kubeconfig-path>`

Reverses gondolin on a cluster, making it visible to Placements again.

Named after *The Fall of Gondolin* by J.R.R. Tolkien — the story of how the Hidden City was revealed and its enchantments broken.

**What it does:**
1. Removes the `gondolin=true:NoSelect` taint (cluster becomes selectable)
2. Waits for Placements to re-select the cluster
3. Waits for the ManifestWorkReplicaSet controller to reconcile (re-adopt existing ManifestWorks)
4. Removes the ValidatingAdmissionPolicy (deletion protection no longer needed)

**Ordering is critical** — the taint is removed before the policy, ensuring the controller re-adopts ManifestWorks before deletion protection is lifted. Workloads are never interrupted.

**Example:**
```
/fall-of-gondolin managed1 /tmp/hub-kubeconfig
```

## Demo

Run `./demo.sh` for an interactive end-to-end demo. Each step advances on key press — nothing auto-plays.

```
./demo.sh
```

The demo walks through four parts:
1. **The Setup** — shows the OCM environment: hub, managed cluster, Placement, ManifestWork pipeline, and a live ConfigMap workload
2. **Without Gondolin** — changes placement so it stops selecting the cluster. The ManifestWork is deleted and the workload disappears. This is the problem.
3. **With Gondolin** — restores the workload, then applies gondolin (VAP + taint). Placement drops the cluster again, but this time the ManifestWork and workload survive. A manual delete attempt is also shown being blocked.
4. **Fall of Gondolin** — reverses the protection with safe ordering. Workload is never interrupted.

The demo is self-contained — pre-recorded output, no external dependencies. Press ENTER to advance each step.

## Using with OpenCode

Gondolin also ships with [OpenCode](https://opencode.ai) commands in `.opencode/commands/`. To use them:

1. **Install OpenCode** (if you haven't already):
   ```
   brew install anomalyco/tap/opencode   # macOS/Linux
   npm i -g opencode-ai@latest           # or via npm
   ```

2. **Launch OpenCode from the repo root:**
   ```
   cd gondolin
   opencode
   ```

3. **Run the commands:**
   ```
   /gondolin managed1 /tmp/hub-kubeconfig
   /fall-of-gondolin managed1 /tmp/hub-kubeconfig
   ```

OpenCode picks up the commands automatically from `.opencode/commands/`. No additional configuration is needed.

## Prerequisites

- Kubernetes 1.30+ (ValidatingAdmissionPolicy GA)
- `ManifestWorkReplicaSet` feature gate enabled on the ClusterManager
- `kubectl` and `jq` available on the CLI
- An AI coding agent running from this directory — either [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [OpenCode](https://opencode.ai)

## Compatibility

Gondolin works with **upstream OCM (open-cluster-management.io)** — no ACM or RHACM dependency required. It has been tested on:

- Kind clusters with `clusteradm` bootstrap (OCM-io)
- OpenShift with RHACM (ACM)

The only requirement is Kubernetes 1.30+ for ValidatingAdmissionPolicy GA support.
