#!/usr/bin/env bash
# Probe whether a BindingPolicy name of a given length downsyncs to ITS (ManifestWorks).
#
# Usage:
#   ./probe_length.sh 63              # single length
#   ./probe_length.sh --sweep 58 70   # linear sweep (inclusive)
#   ./probe_length.sh --binary 58 70  # binary search for first failing length
#
# Requires: workload.yaml already applied on wds1 (Step 3 of REPRO.txt).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubeflex}"
export KUBECONFIG

NS="ursa-namespace-length-probe"
CM="ursa-configmap-length-probe"
WAIT_SECS="${WAIT_SECS:-90}"
EDGE_SETTLE_SECS="${EDGE_SETTLE_SECS:-15}"
PREFIX="bp-len-probe-"
ITS_LABEL="transport.kubestellar.io/originOwnerReferenceBindingKey"

# Set by check_sync after each probe (used in sweep/binary summaries).
LAST_PROBE_POLICY_OK=0
LAST_PROBE_BINDINGS_OK=0
LAST_PROBE_MW_COUNT=0

make_policy_name() {
  local target_len="$1"
  local min_len=$(( ${#PREFIX} + 1 ))
  if (( target_len < min_len )); then
    echo "error: length must be >= ${min_len} (prefix '${PREFIX}')" >&2
    return 1
  fi
  local pad_len=$(( target_len - ${#PREFIX} ))
  python3 -c "print('${PREFIX}' + 'a' * ${pad_len})"
}

write_binding_policy() {
  local name="$1"
  local out="$2"
  cat >"${out}" <<EOF
apiVersion: control.kubestellar.io/v1alpha1
kind: BindingPolicy
metadata:
  name: ${name}
spec:
  clusterSelectors:
  - matchLabels:
      name: edge-1
  - matchLabels:
      name: edge-2
  downsync:
  - objectNames:
    - ${CM}
    - ${NS}
EOF
}

delete_probe_policy() {
  # Binding name equals policy name — match exactly (never grep: bp-len-probe-58 is a prefix of 63).
  local name="$1"
  kubectl --context wds1 delete bindingpolicy "${name}" --ignore-not-found --wait=false 2>/dev/null || true
  if kubectl --context wds1 get bindings.control.kubestellar.io "${name}" >/dev/null 2>&1; then
    kubectl --context wds1 patch "bindings.control.kubestellar.io/${name}" \
      --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    kubectl --context wds1 delete bindings.control.kubestellar.io "${name}" \
      --ignore-not-found --wait=false 2>/dev/null || true
  fi
}

reset_edges_for_probe() {
  for ctx in edge-1 edge-2; do
    kubectl --context "${ctx}" delete namespace "${NS}" --ignore-not-found --wait=false 2>/dev/null || true
  done
  sleep "${EDGE_SETTLE_SECS}"
  kubectl --context wds1 apply -f "${SCRIPT_DIR}/workload.yaml"
}

count_manifestworks_for_policy() {
  local policy_name="$1"
  kubectl --context its1 get manifestworks -n edge-1 \
    -l "${ITS_LABEL}=${policy_name}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

its_manifestworks_yaml_for_policy() {
  local policy_name="$1"
  kubectl --context its1 get manifestworks -n edge-1 \
    -l "${ITS_LABEL}=${policy_name}" \
    -o yaml 2>/dev/null || true
}

check_sync() {
  local name="$1"
  local policy_ok=0 bindings_ok=0 mw_count=0 mw_has_ns=0 mw_has_cm=0 edge_cm=0
  local its_mw_yaml=""

  kubectl --context wds1 get bindingpolicy "${name}" >/dev/null 2>&1 && policy_ok=1
  kubectl --context wds1 get bindings.control.kubestellar.io "${name}" >/dev/null 2>&1 && bindings_ok=1

  mw_count="$(count_manifestworks_for_policy "${name}")"
  its_mw_yaml="$(its_manifestworks_yaml_for_policy "${name}")"

  if printf '%s\n' "${its_mw_yaml}" | grep -qE "^[[:space:]]+kind: Namespace$"; then
    if printf '%s\n' "${its_mw_yaml}" | grep -qE "^[[:space:]]+name: ${NS}$"; then
      mw_has_ns=1
    fi
  fi
  if printf '%s\n' "${its_mw_yaml}" | grep -qE "^[[:space:]]+kind: ConfigMap$"; then
    if printf '%s\n' "${its_mw_yaml}" | grep -qE "^[[:space:]]+name: ${CM}$"; then
      mw_has_cm=1
    fi
  fi

  if kubectl --context edge-1 get configmap "${CM}" -n "${NS}" >/dev/null 2>&1; then
    edge_cm=1
  fi

  echo "  wds BindingPolicy:              ${policy_ok}"
  echo "  wds Binding object:             ${bindings_ok}"
  echo "  its1 MW count (this policy):    ${mw_count}"
  echo "  its1 MW carries Namespace:      ${mw_has_ns}"
  echo "  its1 MW carries ConfigMap:      ${mw_has_cm}"
  echo "  edge-1 ConfigMap:               ${edge_cm}"

  LAST_PROBE_POLICY_OK="${policy_ok}"
  LAST_PROBE_BINDINGS_OK="${bindings_ok}"
  LAST_PROBE_MW_COUNT="${mw_count}"

  # Primary signal: ITS transport created ManifestWorks for THIS policy label.
  if (( mw_count >= 2 && mw_has_ns && mw_has_cm && edge_cm )); then
    return 0
  fi

  if (( policy_ok && bindings_ok && mw_count == 0 )); then
    echo "  >>> BUG SIGNATURE: BindingPolicy + Binding on WDS, zero ManifestWorks on ITS"
  elif (( policy_ok && !bindings_ok && mw_count == 0 )); then
    echo "  >>> FAIL: BindingPolicy on WDS but no Binding object (transport never started)"
  elif (( policy_ok && mw_count == 0 )); then
    echo "  >>> FAIL: policy on WDS, zero ManifestWorks on ITS for this policy"
  elif (( policy_ok && mw_count >= 2 && ! edge_cm )); then
    echo "  >>> ITS has ManifestWorks but edge object missing (wait longer or check klusterlet)"
  fi
  return 1
}

probe_one() {
  local target_len="$1"
  local name
  name="$(make_policy_name "${target_len}")"
  local actual_len=${#name}

  echo "=== length=${target_len} name='${name}' (actual=${actual_len}) ==="

  delete_probe_policy "${name}"
  reset_edges_for_probe

  local tmp
  tmp="$(mktemp)"
  write_binding_policy "${name}" "${tmp}"
  kubectl --context wds1 apply -f "${tmp}"
  rm -f "${tmp}"

  echo "Waiting ${WAIT_SECS}s for transport..."
  sleep "${WAIT_SECS}"

  if check_sync "${name}"; then
    echo "RESULT: PASS"
    echo
    return 0
  fi
  echo "RESULT: FAIL"
  echo
  return 1
}

print_boundary_summary() {
  local mode="$1" last_pass="$2" first_fail="$3" fail_bindings="${4:-}" fail_mw="${5:-}"
  echo "=== ${mode} summary ==="
  echo "last PASS length:  ${last_pass:-none}"
  echo "first FAIL length: ${first_fail:-none}"
  if [[ -n "${last_pass}" && -n "${first_fail}" ]]; then
    echo "boundary: length <= ${last_pass} reaches ITS; length >= ${first_fail} does not"
    if [[ "${first_fail}" -eq $(( last_pass + 1 )) ]]; then
      echo "exact limit: ${last_pass} characters PASS; ${first_fail} characters FAIL"
    fi
  fi
  if [[ -n "${first_fail}" && -n "${fail_bindings}" ]]; then
    echo "at first FAIL (length ${first_fail}): WDS Binding object=${fail_bindings}, ITS ManifestWorks=${fail_mw}"
  fi
}

usage() {
  cat <<EOF
Usage:
  $0 <length>                 Probe one name length (characters)
  $0 --sweep <min> <max>        Linear sweep inclusive
  $0 --binary <min> <max>       Binary search: first length that FAILS sync

Environment:
  WAIT_SECS          Seconds to wait after apply (default: 90)
  EDGE_SETTLE_SECS   Seconds after edge namespace delete (default: 15)
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    --sweep)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      local lo="$2" hi="$3" len pass_at="" fail_at="" fail_bindings="" fail_mw=""
      for (( len=lo; len<=hi; len++ )); do
        if probe_one "${len}"; then
          pass_at="${len}"
        elif [[ -z "${fail_at}" ]]; then
          fail_at="${len}"
          fail_bindings="${LAST_PROBE_BINDINGS_OK}"
          fail_mw="${LAST_PROBE_MW_COUNT}"
        fi
      done
      print_boundary_summary "sweep ${lo}-${hi}" "${pass_at}" "${fail_at}" \
        "${fail_bindings}" "${fail_mw}"
      ;;
    --binary)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      lo="$2"
      hi="$3"
      local last_pass="" first_fail="" fail_bindings="" fail_mw=""
      while (( lo <= hi )); do
        local mid=$(( (lo + hi) / 2 ))
        if probe_one "${mid}"; then
          last_pass="${mid}"
          lo=$(( mid + 1 ))
        else
          if [[ -z "${first_fail}" || mid -lt first_fail ]]; then
            first_fail="${mid}"
            fail_bindings="${LAST_PROBE_BINDINGS_OK}"
            fail_mw="${LAST_PROBE_MW_COUNT}"
          fi
          hi=$(( mid - 1 ))
        fi
      done
      print_boundary_summary "binary search" "${last_pass}" "${first_fail}" \
        "${fail_bindings}" "${fail_mw}"
      ;;
    -h|--help)
      usage
      ;;
    *)
      probe_one "$1"
      ;;
  esac
}

main "$@"
