#!/usr/bin/env bash
# Remove bug-repro BindingPolicies, bindings, and workloads.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubeflex}"
export KUBECONFIG

NS="ursa-namespace-bug-repro"
CM="ursa-configmap-bug-repro"
POLICIES=(
  bp-bug-repro-pass-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  bp-bug-repro-fail-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
)

echo "Deleting BindingPolicies from wds1..."
for p in "${POLICIES[@]}"; do
  kubectl --context wds1 delete bindingpolicy "${p}" --ignore-not-found --wait=false
done

echo "Clearing Bindings on wds1..."
for p in "${POLICIES[@]}"; do
  if kubectl --context wds1 get bindings.control.kubestellar.io "${p}" >/dev/null 2>&1; then
    kubectl --context wds1 patch "bindings.control.kubestellar.io/${p}" \
      --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    kubectl --context wds1 delete bindings.control.kubestellar.io "${p}" --ignore-not-found --wait=false
  fi
done

echo "Deleting workloads from wds1..."
kubectl --context wds1 delete configmap "${CM}" -n "${NS}" --ignore-not-found
kubectl --context wds1 delete namespace "${NS}" --ignore-not-found --wait=false

for ctx in edge-1 edge-2; do
  echo "Deleting workloads from ${ctx}..."
  kubectl --context "${ctx}" delete configmap "${CM}" -n "${NS}" --ignore-not-found
  kubectl --context "${ctx}" delete namespace "${NS}" --ignore-not-found --wait=false
done

echo "Cleanup issued. Wait ~60s before re-running."
