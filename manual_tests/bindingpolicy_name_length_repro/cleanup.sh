#!/usr/bin/env bash
# Remove length-probe BindingPolicies, bindings, and workloads.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubeflex}"
export KUBECONFIG

NS="ursa-namespace-length-probe"
CM="ursa-configmap-length-probe"

echo "Deleting BindingPolicies from wds1 (bp-len-probe-* and known catalog names)..."
kubectl --context wds1 get bindingpolicy -o name 2>/dev/null \
  | grep -E 'bindingpolicy\.control\.kubestellar\.io/(bp-len-probe-|ursa-.*-template-policy-)' \
  | xargs -r kubectl --context wds1 delete --ignore-not-found --wait=false

echo "Clearing stuck Bindings (transport finalizer) on wds1..."
for b in $(kubectl --context wds1 get bindings.control.kubestellar.io -o name 2>/dev/null || true); do
  kubectl --context wds1 patch "${b}" --type=merge -p '{"metadata":{"finalizers":null}}' --ignore-not-found 2>/dev/null || true
done
kubectl --context wds1 delete bindings.control.kubestellar.io --all --ignore-not-found --wait=false 2>/dev/null || true

echo "Deleting workloads from wds1..."
kubectl --context wds1 delete configmap "${CM}" -n "${NS}" --ignore-not-found
kubectl --context wds1 delete namespace "${NS}" --ignore-not-found --wait=false

for ctx in edge-1 edge-2; do
  echo "Deleting workloads from ${ctx}..."
  kubectl --context "${ctx}" delete configmap "${CM}" -n "${NS}" --ignore-not-found
  kubectl --context "${ctx}" delete namespace "${NS}" --ignore-not-found --wait=false
done

echo "Cleanup issued. Wait ~60s before re-running a probe."
