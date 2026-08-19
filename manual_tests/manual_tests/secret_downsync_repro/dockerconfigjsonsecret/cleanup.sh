#!/usr/bin/env bash
# Remove all dockerconfigjson repro policies and workloads from WDS and edges.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubeflex}"
export KUBECONFIG

NS="ursa-namespace-template"
POLICIES=(
  repro-dockerconfigjson-case1-namespace-only
  repro-dockerconfigjson-case2-with-configmap
  repro-dockerconfigjson-case3-with-pod
  ursa-bp-dockerconfigjsonsecret
  ursa-dockerconfigjsonsecret-template-policy-ursa-dockerconfigjsonsecret-template
)

echo "Deleting BindingPolicies from wds1..."
for p in "${POLICIES[@]}"; do
  kubectl --context wds1 delete bindingpolicy "${p}" --ignore-not-found --wait=false
done

echo "Clearing stuck Bindings (transport finalizer) on wds1..."
for b in $(kubectl --context wds1 get bindings.control.kubestellar.io -o name 2>/dev/null || true); do
  kubectl --context wds1 patch "${b}" --type=merge -p '{"metadata":{"finalizers":null}}' --ignore-not-found 2>/dev/null || true
done
kubectl --context wds1 delete bindings.control.kubestellar.io --all --ignore-not-found --wait=false 2>/dev/null || true

echo "Deleting workloads from wds1..."
kubectl --context wds1 delete pod repro-pod-dockerconfigjson -n "${NS}" --ignore-not-found --wait=false
kubectl --context wds1 delete configmap repro-configmap-dockerconfigjson -n "${NS}" --ignore-not-found
kubectl --context wds1 delete secret ursa-dockerconfigjsonsecret-template -n "${NS}" --ignore-not-found
kubectl --context wds1 delete namespace "${NS}" --ignore-not-found --wait=false

for ctx in edge-1 edge-2; do
  echo "Deleting workloads from ${ctx}..."
  kubectl --context "${ctx}" delete pod repro-pod-dockerconfigjson -n "${NS}" --ignore-not-found --wait=false
  kubectl --context "${ctx}" delete configmap repro-configmap-dockerconfigjson -n "${NS}" --ignore-not-found
  kubectl --context "${ctx}" delete secret ursa-dockerconfigjsonsecret-template -n "${NS}" --ignore-not-found
  kubectl --context "${ctx}" delete namespace "${NS}" --ignore-not-found --wait=false
done

echo "Cleanup issued. Wait ~60s before re-running a case."
sleep 5
