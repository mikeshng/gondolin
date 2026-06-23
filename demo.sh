#!/bin/bash
# Gondolin Demo: Protecting Workloads on Hidden Clusters
# Press ENTER to advance through each step

BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[0;33m"
GREY="\033[0;90m"
RED="\033[0;31m"
RESET="\033[0m"

PROMPT="${GREEN}\$ ${RESET}"

type_cmd() {
  local cmd="$1"
  printf "${PROMPT}"
  printf "${BOLD}%s${RESET}" "$cmd"
  echo ""
}

show_output() {
  echo -e "$1"
}

wait_for_enter() {
  read -rs
}

section() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}  $1${RESET}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
}

comment() {
  echo -e "${GREY}# $1${RESET}"
}

step() {
  local cmd="$1"
  local output="$2"
  wait_for_enter
  type_cmd "$cmd"
  sleep 0.3
  show_output "$output"
}

clear
echo ""
echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo -e "${BOLD}${CYAN}  Gondolin: Protecting Workloads on Hidden Clusters${RESET}"
echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo ""
echo -e "${GREY}  \"Gondolin was the greatest and most glorious Elven city${RESET}"
echo -e "${GREY}   of the First Age. Also known as the Hidden City...\"${RESET}"
echo ""
echo -e "${GREY}  Press ENTER to advance through each step${RESET}"
echo ""

###############################################################################
section "PART 1: The Setup — OCM Workload Distribution"
###############################################################################

echo -e "  In OCM, the common pattern for distributing workloads is:"
echo ""
echo -e "  ${BOLD}Placement${RESET} selects which clusters receive work (by labels, scores, etc.)"
echo -e "  A controller watches the Placement and creates a ${BOLD}ManifestWork${RESET} for"
echo -e "  each selected cluster — a bundle of Kubernetes resources applied there."
echo ""
echo -e "  ${CYAN}Placement → PlacementDecision → ManifestWork → workload on cluster${RESET}"
echo ""
echo -e "  Addons, ManifestWorkReplicaSet, and other OCM consumers all follow"
echo -e "  this same pattern. Here we use MWRS as the example, but the problem"
echo -e "  — and the solution — applies to anything that creates ManifestWorks"
echo -e "  based on Placement decisions."
echo ""
comment "Let's see it: a hub, a managed cluster, and a ConfigMap deployed via this pipeline"

step 'kubectl get managedclusters' \
'NAME       HUB ACCEPTED   MANAGED CLUSTER URLS                  JOINED   AVAILABLE   AGE
managed1   true           https://managed1-control-plane:6443   True     True        10m'

comment "Placement selects managed1 (1 cluster matched)"

step 'kubectl get placement demo-placement -n default' \
'NAME             SUCCEEDED   REASON                  SELECTEDCLUSTERS
demo-placement   True        AllDecisionsScheduled   1'

comment "A controller watches this Placement and creates ManifestWorks for selected clusters"

step 'kubectl get manifestworkreplicaset demo-workload -n default' \
'NAME            PLACEMENT    FOUND   MANIFESTWORKS   APPLIED
demo-workload   AsExpected   True    AsExpected      True'

comment "The controller created a ManifestWork in managed1's namespace on the hub"

step 'kubectl get manifestworks -n managed1' \
'NAME            AGE
demo-workload   5m'

comment "That ManifestWork deployed a ConfigMap to managed1 — our workload is live"

step 'kubectl get configmap demo-configmap -n default --context kind-managed1 -o yaml' \
'apiVersion: v1
data:
  deployed-by: ocm-placement
  message: Hello from OCM ManifestWorkReplicaSet!
  target-cluster: managed1
kind: ConfigMap
metadata:
  name: demo-configmap
  namespace: default'

###############################################################################
section "PART 2: Without Gondolin — The Problem"
###############################################################################

echo -e "  Here is the problem we are solving."
echo ""
echo -e "  When a Placement ${BOLD}stops selecting${RESET} a cluster — whether because"
echo -e "  labels changed, a predicate was updated, or the cluster was removed"
echo -e "  from a ClusterSet — the controller ${RED}${BOLD}deletes${RESET} the ManifestWork for"
echo -e "  that cluster. The work agent then removes all the resources it applied."
echo ""
echo -e "  This is by design — placement-driven lifecycle. But sometimes you"
echo -e "  want to ${BOLD}hide a cluster from scheduling without killing its workloads${RESET}:"
echo -e "  maintenance windows, emergency isolation, controlled draining."
echo ""
echo -e "  Let's see the default behavior first."
echo ""

comment "Change placement to select a cluster that doesn't exist"

step 'kubectl patch placement demo-placement -n default --type=merge \
  -p '"'"'{"spec":{"predicates":[{"requiredClusterSelector":{"labelSelector":{"matchLabels":{"name":"nonexistent"}}}}]}}'"'"'' \
'placement.cluster.open-cluster-management.io/demo-placement patched'

comment "Placement now selects 0 clusters"

step 'kubectl get placement demo-placement -n default' \
'NAME             SUCCEEDED   REASON                    SELECTEDCLUSTERS
demo-placement   False       NoManagedClusterMatched   0'

echo ""
echo -e "${RED}${BOLD}The ManifestWork is GONE — the controller deleted it:${RESET}"

step 'kubectl get manifestworks -n managed1' \
'No resources found in managed1 namespace.'

echo -e "${RED}${BOLD}And the ConfigMap on the managed cluster is DELETED:${RESET}"

step 'kubectl get configmap demo-configmap -n default --context kind-managed1' \
'Error from server (NotFound): configmaps "demo-configmap" not found'

echo ""
echo -e "${YELLOW}${BOLD}This is the problem. The cluster lost its workload just because${RESET}"
echo -e "${YELLOW}${BOLD}placement stopped selecting it.${RESET}"
echo ""

###############################################################################
section "PART 3: With Gondolin — The Solution"
###############################################################################

echo -e "  Gondolin solves this with two Kubernetes-native mechanisms:"
echo ""
echo -e "  1. ${BOLD}ValidatingAdmissionPolicy${RESET} — a policy on the hub that blocks"
echo -e "     all DELETE operations on ManifestWorks in the cluster's namespace."
echo -e "     Any controller that tries to delete gets denied. Workload survives."
echo ""
echo -e "  2. ${BOLD}ManagedCluster Taint${RESET} — a gondolin=true:NoSelect taint that"
echo -e "     tells all Placements to stop selecting this cluster."
echo ""
echo -e "  The policy must be active ${BOLD}before${RESET} the taint — otherwise there is a"
echo -e "  window where the controller deletes before the policy takes effect."
echo ""
echo -e "  Let's see it in action."
echo ""

comment "First, restore placement so the workload comes back"

step 'kubectl patch placement demo-placement -n default --type=merge \
  -p '"'"'{"spec":{"predicates":[{"requiredClusterSelector":{"labelSelector":{"matchLabels":{"name":"managed1"}}}}]}}'"'"'' \
'placement.cluster.open-cluster-management.io/demo-placement patched'

comment "Workload re-deployed automatically by the controller"

step 'kubectl get manifestworks -n managed1' \
'NAME            AGE
demo-workload   10s'

step 'kubectl get configmap demo-configmap -n default --context kind-managed1 -o jsonpath="{.data.message}"' \
'Hello from OCM ManifestWorkReplicaSet!'

echo ""
comment "Good — workload is back. Now apply Gondolin."
echo ""

comment "Step 1: Create the admission policy to block ManifestWork deletion"

step 'kubectl apply -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: gondolin-managed1
spec:
  failurePolicy: Fail
  matchConstraints:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: "managed1"
    resourceRules:
    - apiGroups: ["work.open-cluster-management.io"]
      apiVersions: ["v1"]
      operations: ["DELETE"]
      resources: ["manifestworks"]
  validations:
  - expression: "false"
    message: "Gondolin: ManifestWork deletion is blocked — cluster managed1 is hidden"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: gondolin-managed1
spec:
  policyName: gondolin-managed1
  validationActions:
  - Deny
EOF' \
'validatingadmissionpolicy.admissionregistration.k8s.io/gondolin-managed1 created
validatingadmissionpolicybinding.admissionregistration.k8s.io/gondolin-managed1 created'

comment "Step 2: Verify the policy is active (dry-run delete must be denied)"

step 'kubectl delete manifestwork demo-workload -n managed1 --dry-run=server' \
'The manifestworks "demo-workload" is invalid: : ValidatingAdmissionPolicy
'"'"'gondolin-managed1'"'"' with binding '"'"'gondolin-managed1'"'"' denied request:
Gondolin: ManifestWork deletion is blocked — cluster managed1 is hidden'

echo ""
echo -e "${GREEN}${BOLD}Policy is active. Deletion is blocked. Safe to add the taint.${RESET}"
echo ""

comment "Step 3: Add the gondolin taint to hide the cluster from all Placements"

step 'kubectl patch managedcluster managed1 --type=merge \
  -p '"'"'{"spec":{"taints":[{"key":"gondolin","value":"true","effect":"NoSelect"}]}}'"'"'' \
'managedcluster.cluster.open-cluster-management.io/managed1 patched'

comment "Placement drops the cluster — same as Part 2..."

step 'kubectl get placement demo-placement -n default' \
'NAME             SUCCEEDED   REASON                    SELECTEDCLUSTERS
demo-placement   False       NoManagedClusterMatched   0'

echo ""
echo -e "${GREEN}${BOLD}But this time the ManifestWork is STILL THERE:${RESET}"

step 'kubectl get manifestworks -n managed1' \
'NAME            AGE
demo-workload   2m'

echo -e "${GREEN}${BOLD}And the ConfigMap is STILL ALIVE on the managed cluster:${RESET}"

step 'kubectl get configmap demo-configmap -n default --context kind-managed1 -o jsonpath="{.data.message}"' \
'Hello from OCM ManifestWorkReplicaSet!'

comment "Even a manual delete attempt is blocked:"

step 'kubectl delete manifestwork demo-workload -n managed1' \
'The manifestworks "demo-workload" is invalid: : ValidatingAdmissionPolicy
'"'"'gondolin-managed1'"'"' with binding '"'"'gondolin-managed1'"'"' denied request:
Gondolin: ManifestWork deletion is blocked — cluster managed1 is hidden'

echo ""
echo -e "${GREEN}${BOLD}Cluster is hidden from scheduling. Workload is protected.${RESET}"
echo -e "${GREEN}${BOLD}No controller, no user, nothing can delete it.${RESET}"
echo ""

###############################################################################
section "PART 4: Fall of Gondolin — Lifting the Protection"
###############################################################################

echo -e "  Named after ${BOLD}The Fall of Gondolin${RESET} by J.R.R. Tolkien — the story"
echo -e "  of how the Hidden City was revealed and its enchantments broken."
echo ""
echo -e "  Reversing gondolin requires careful ordering:"
echo ""
echo -e "  1. Remove the taint ${BOLD}first${RESET} — so Placement re-selects the cluster"
echo -e "  2. Wait for the controller to reconcile — it sees the ManifestWork"
echo -e "     already exists and re-adopts it (no delete, no re-create)"
echo -e "  3. Remove the admission policy ${BOLD}last${RESET} — deletion protection stays"
echo -e "     active until the controller has re-adopted the ManifestWork"
echo ""
echo -e "  The workload is never interrupted at any point in this process."
echo ""

comment "Step 1: Remove the gondolin taint"

step 'kubectl patch managedcluster managed1 --type=merge \
  -p '"'"'{"spec":{"taints":[]}}'"'"'' \
'managedcluster.cluster.open-cluster-management.io/managed1 patched'

comment "Step 2: Placement re-selects the cluster"

step 'kubectl get placement demo-placement -n default' \
'NAME             SUCCEEDED   REASON                  SELECTEDCLUSTERS
demo-placement   True        AllDecisionsScheduled   1'

comment "Controller re-adopted the existing ManifestWork — same one, never deleted"

step 'kubectl get manifestworkreplicaset demo-workload -n default' \
'NAME            PLACEMENT    FOUND   MANIFESTWORKS   APPLIED
demo-workload   AsExpected   True    AsExpected      True'

comment "Step 3: Safe to remove the admission policy now"

step 'kubectl delete validatingadmissionpolicybinding gondolin-managed1
kubectl delete validatingadmissionpolicy gondolin-managed1' \
'validatingadmissionpolicybinding.admissionregistration.k8s.io "gondolin-managed1" deleted
validatingadmissionpolicy.admissionregistration.k8s.io "gondolin-managed1" deleted'

###############################################################################
section "Final State"
###############################################################################

comment "Everything is back to normal. Workload was NEVER interrupted."

step 'kubectl get placement demo-placement -n default' \
'NAME             SUCCEEDED   REASON                  SELECTEDCLUSTERS
demo-placement   True        AllDecisionsScheduled   1'

step 'kubectl get manifestworks -n managed1' \
'NAME            AGE
demo-workload   5m'

step 'kubectl get configmap demo-configmap -n default --context kind-managed1 -o jsonpath="{.data.message}"' \
'Hello from OCM ManifestWorkReplicaSet!'

echo ""
echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo -e "${BOLD}What we demonstrated:${RESET}"
echo ""
echo -e "  ${RED}Without Gondolin${RESET}  workload was deleted when placement changed"
echo -e "  ${GREEN}With Gondolin${RESET}     workload survived — protected by admission policy"
echo -e "  ${CYAN}Fall of Gondolin${RESET}  protection lifted, workload seamlessly re-adopted"
echo ""
echo -e "${BOLD}${GREEN}Thank you!${RESET}"
echo ""
wait_for_enter
