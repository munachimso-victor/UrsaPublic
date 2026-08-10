#!/usr/bin/env bash
# Verify WDS / ITS / edge state for one dockerconfigjson repro case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubeflex}"
export KUBECONFIG

CASE="${1:-case1_namespace_only}"
SECRET_NS="ursa-namespace-template"
SECRET_NAME="ursa-dockerconfigjsonsecret-template"

case "${CASE}" in
  case1_namespace_only)
    POLICY_NAME="repro-dockerconfigjson-case1-namespace-only"
    EXTRA_CM=""
    EXTRA_POD=""
    ;;
  case2_with_configmap)
    POLICY_NAME="repro-dockerconfigjson-case2-with-configmap"
    EXTRA_CM="repro-configmap-dockerconfigjson"
    EXTRA_POD=""
    ;;
  case3_with_pod)
    POLICY_NAME="repro-dockerconfigjson-case3-with-pod"
    EXTRA_CM=""
    EXTRA_POD="repro-pod-dockerconfigjson"
    ;;
  case4_ursa_exact)
    POLICY_NAME="ursa-bp-dockerconfigjsonsecret"
    EXTRA_CM=""
    EXTRA_POD=""
    ;;
  *)
    echo "Usage: $0 [case1_namespace_only|case2_with_configmap|case3_with_pod|case4_ursa_exact]"
    exit 2
    ;;
esac

section() {
  echo
  echo "---- $1 ----"
}

echo "================================================================================"
echo "dockerconfigjson secret downsync verification"
echo "  case=${CASE}"
echo "  KUBECONFIG=${KUBECONFIG}"
echo "  secret=${SECRET_NS}/${SECRET_NAME}"
echo "  policy=${POLICY_NAME}"
echo "================================================================================"

section "WDS: namespace + secret"
kubectl --context wds1 get namespace "${SECRET_NS}" -o wide 2>&1 || true
kubectl --context wds1 get secret "${SECRET_NAME}" -n "${SECRET_NS}" -o wide 2>&1 || true

if [[ -n "${EXTRA_CM}" ]]; then
  section "WDS: companion ConfigMap"
  kubectl --context wds1 get configmap "${EXTRA_CM}" -n "${SECRET_NS}" -o wide 2>&1 || true
fi

if [[ -n "${EXTRA_POD}" ]]; then
  section "WDS: companion Pod"
  kubectl --context wds1 get pod "${EXTRA_POD}" -n "${SECRET_NS}" -o wide 2>&1 || true
fi

section "WDS: BindingPolicy"
kubectl --context wds1 get bindingpolicy "${POLICY_NAME}" -o yaml 2>&1 | head -45 || true

section "WDS: Binding (companion CR)"
kubectl --context wds1 get bindings.control.kubestellar.io "${POLICY_NAME}" -o custom-columns=\
'NAME:.metadata.name,DELETING:.metadata.deletionTimestamp,AGE:.metadata.creationTimestamp,OBSGEN:.status.observedGeneration' 2>&1 || true

for EDGE in edge-1 edge-2; do
  section "ITS (${EDGE}): ManifestWorks"
  kubectl --context its1 get manifestworks -n "${EDGE}" -o name 2>&1 || true
  kubectl --context its1 get manifestworks -n "${EDGE}" -o yaml 2>/dev/null | \
    grep -E "kind:|name:|namespace:|Applied|Available|${SECRET_NAME}|${SECRET_NS}|${EXTRA_CM}|${EXTRA_POD}" | \
    head -50 || echo "(no manifestworks or no grep matches)"

  section "Edge (${EDGE}): namespace + secret"
  kubectl --context "${EDGE}" get namespace "${SECRET_NS}" 2>&1 || true
  kubectl --context "${EDGE}" get secret "${SECRET_NAME}" -n "${SECRET_NS}" 2>&1 || \
    echo "MISSING: ${SECRET_NAME} not on ${EDGE}"

  if [[ -n "${EXTRA_CM}" ]]; then
    section "Edge (${EDGE}): companion ConfigMap"
    kubectl --context "${EDGE}" get configmap "${EXTRA_CM}" -n "${SECRET_NS}" 2>&1 || \
      echo "MISSING: ${EXTRA_CM} not on ${EDGE}"
  fi

  if [[ -n "${EXTRA_POD}" ]]; then
    section "Edge (${EDGE}): companion Pod"
    kubectl --context "${EDGE}" get pod "${EXTRA_POD}" -n "${SECRET_NS}" 2>&1 || \
      echo "MISSING: ${EXTRA_POD} not on ${EDGE}"
  fi
done

section "Summary"
wds_secret=0
edge1_secret=0
edge2_secret=0
edge1_cm=1
edge2_cm=1
edge1_pod=1
edge2_pod=1

kubectl --context wds1 get secret "${SECRET_NAME}" -n "${SECRET_NS}" >/dev/null 2>&1 && wds_secret=1
kubectl --context edge-1 get secret "${SECRET_NAME}" -n "${SECRET_NS}" >/dev/null 2>&1 && edge1_secret=1
kubectl --context edge-2 get secret "${SECRET_NAME}" -n "${SECRET_NS}" >/dev/null 2>&1 && edge2_secret=1

if [[ -n "${EXTRA_CM}" ]]; then
  edge1_cm=0
  edge2_cm=0
  kubectl --context edge-1 get configmap "${EXTRA_CM}" -n "${SECRET_NS}" >/dev/null 2>&1 && edge1_cm=1
  kubectl --context edge-2 get configmap "${EXTRA_CM}" -n "${SECRET_NS}" >/dev/null 2>&1 && edge2_cm=1
fi

if [[ -n "${EXTRA_POD}" ]]; then
  edge1_pod=0
  edge2_pod=0
  kubectl --context edge-1 get pod "${EXTRA_POD}" -n "${SECRET_NS}" >/dev/null 2>&1 && edge1_pod=1
  kubectl --context edge-2 get pod "${EXTRA_POD}" -n "${SECRET_NS}" >/dev/null 2>&1 && edge2_pod=1
fi

echo "  WDS has secret:        ${wds_secret} (1=yes)"
echo "  edge-1 has secret:     ${edge1_secret} (1=yes)"
echo "  edge-2 has secret:     ${edge2_secret} (1=yes)"
[[ -n "${EXTRA_CM}" ]] && echo "  edge-1 has configmap:  ${edge1_cm} (1=yes)"
[[ -n "${EXTRA_CM}" ]] && echo "  edge-2 has configmap:  ${edge2_cm} (1=yes)"
[[ -n "${EXTRA_POD}" ]] && echo "  edge-1 has pod:        ${edge1_pod} (1=yes)"
[[ -n "${EXTRA_POD}" ]] && echo "  edge-2 has pod:        ${edge2_pod} (1=yes)"

if [[ "${wds_secret}" -eq 1 && "${edge1_secret}" -eq 0 && "${edge2_secret}" -eq 0 ]]; then
  echo
  echo "FAILURE REPRODUCED: secret on WDS but NOT on edges (case ${CASE})."
  exit 1
fi

if [[ "${wds_secret}" -eq 1 && "${edge1_secret}" -eq 1 && "${edge2_secret}" -eq 1 ]]; then
  echo
  echo "Secret synced to both edges — failure NOT reproduced for case ${CASE}."
  exit 0
fi

echo
echo "Partial or unexpected state — inspect sections above."
exit 2
