# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`[Bug]: Static Service clusterIP / nodePort lost on downsync — wrap strips cluster-local fields`

Paste below the line into a new issue. Attach `sample_log.txt` and
`kubestellar-snapshot.tar.gz` (optional but helpful).

---

### Describe the bug

Hi KubeStellar Maintainers,

We found that **user-specified Service cluster-local fields** do not survive downsync to a WEC, even when the hub object retains them.

Seeds set explicit `spec.clusterIP` (ClusterIP and NodePort types) and `ports[].nodePort` (NodePort). Applying the same YAML **directly on the spoke** keeps those values. Applying via **WDS downsync** leaves the hub/WDS object with the seed values, but the **ManifestWork wrap omits** `clusterIP`, `clusterIPs`, and the user-set `nodePort`. The spoke apiserver then **auto-allocates** different values. ManifestWork stays **`Applied=True` / `Available=True`** — this is not a failed apply; it is **desired-vs-live drift** on cluster-local Service spec.

We reproduced on the **same WEC (`edge-1`)** with the **same `service_seed.yaml`**: Phase A direct apply binds cleanly; Phase B hub downsync breaks it on that same cluster.

### Details

On a normal single cluster (direct `kubectl apply` on the spoke):

1. Service created with fixed `clusterIP` and/or `nodePort`.
2. Apiserver accepts the user values (when valid and free).
3. Live Service matches the seed.

Under KubeStellar downsync:

1. WDS apply creates the Service with the seed values on the hub.
2. Transport wraps the live WDS object into ManifestWork but **strips** `clusterIP`, `clusterIPs`, and user-set `nodePort` (wrap shows `nodePort: null`).
3. Work-agent applies the stripped manifest on the spoke.
4. Spoke apiserver allocates **its own** clusterIP / nodePort.

**Manual repro results** (`sample_log.txt` in bundle):

| Service | Phase | clusterIP | nodePort |
|---------|-------|-----------|----------|
| `ursa-clusterip-static-template` | Phase A (direct edge-1) | `10.96.100.100` | — |
| | WDS after downsync | `10.96.100.100` | — |
| | edge-1 after downsync | **`10.96.201.210`** | — |
| `ursa-nodeport-backdoor-fullymanual-template` | Phase A (direct edge-1) | `10.96.100.222` | `32222` |
| | WDS after downsync | `10.96.100.222` | `32222` |
| | edge-1 after downsync | **`10.96.87.32`** | **`31850`** |

**ManifestWork wrap** (both Services): no `spec.clusterIP` / `spec.clusterIPs`; `ports[].nodePort: null` — not the hub-assigned port.

**Ursa automated hits:**

- `tests/all_baselines_10shards/shard8/run_baseline_reset_always/testcase_003_ursa-bp-clusterip-static_original.txt`
- `tests/all_baselines_10shards/shard8/run_baseline_reset_always/testcase_009_ursa-bp-nodeport-backdoor-fullymanual_original.txt`
- `tests/all_baselines_10shards/shard2/run_baseline_reset_always/testcase_009_ursa-bp-ingress_original.txt` (related; static ClusterIP backend Service only)

This is **not a Kubernetes limitation**: the same `service_seed.yaml` applied directly on `edge-1` (Phase A) binds the static `clusterIP` and `nodePort` successfully. Downsync should produce the same live state as that direct apply.

### Steps To Reproduce

Self-contained bundle:

`manual_tests/service_clusterip_nodeport_repro/`

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** same WEC (`edge-1`) and same `service_seed.yaml` twice — direct apply (control), then WDS downsync after cleanup (bug).

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/service_clusterip_nodeport_repro
chmod +x install_requirements.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar cluster setup

```bash
export KUBECONFIG=~/.kube/kubeflex
./setup_kubestellar.sh
kubectl --context edge-1 apply -f fix-klusterlet-rbac.yaml
```

#### Step 3 — Phase A (control): direct apply on edge-1

```bash
kubectl --context edge-1 apply -f service_seed.yaml
kubectl --context edge-1 get svc -n ursa-namespace-template ursa-clusterip-static-template \
  -o jsonpath='clusterIP={.spec.clusterIP}{"\n"}'
kubectl --context edge-1 get svc -n ursa-namespace-template ursa-nodeport-backdoor-fullymanual-template \
  -o jsonpath='clusterIP={.spec.clusterIP} nodePort={.spec.ports[0].nodePort}{"\n"}'
```

Expected: `10.96.100.100` and `10.96.100.222` / `32222`.

#### Step 4 — Cleanup edge-1

```bash
kubectl --context edge-1 delete -f service_seed.yaml --ignore-not-found --wait=false
sleep 30
```

#### Step 5 — Phase B (bug): WDS + BindingPolicy

```bash
kubectl --context wds1 apply -f service_seed.yaml
kubectl --context wds1 apply -f service_policy.yaml
sleep 45
```

#### Step 6 — Compare hub vs edge

```bash
for SVC in ursa-clusterip-static-template \
           ursa-nodeport-backdoor-fullymanual-template; do
  echo "=== $SVC ==="
  kubectl --context wds1 get svc -n ursa-namespace-template "$SVC" \
    -o jsonpath='WDS clusterIP={.spec.clusterIP} clusterIPs={.spec.clusterIPs} nodePort={.spec.ports[0].nodePort}{"\n"}'
  kubectl --context edge-1 get svc -n ursa-namespace-template "$SVC" \
    -o jsonpath='edge clusterIP={.spec.clusterIP} clusterIPs={.spec.clusterIPs} nodePort={.spec.ports[0].nodePort}{"\n"}'
done
```

Expected: WDS keeps seed values; edge has **different** allocator values.

#### Step 7 — ManifestWork wrapped Service snapshot

```bash
kubectl --context its1 -n edge-1 get manifestworks -o yaml > /tmp/repro-mw-edge-1.yaml
for SVC in ursa-clusterip-static-template \
           ursa-nodeport-backdoor-fullymanual-template; do
  echo "=== $SVC ==="
  grep -B5 -A20 "name: ${SVC}" /tmp/repro-mw-edge-1.yaml | grep -A20 'kind: Service' | head -21
done
```

Expected: no `spec.clusterIP` / `spec.clusterIPs`; `nodePort: null` (not seed `32222`).

### Expected behavior

After downsync, the spoke Service **live state must match the hub desired state** — no drift on user-specified `spec.clusterIP`, `spec.clusterIPs`, or `ports[].nodePort`.

When the hub/WDS object carries static values (as in our seed), the spoke must retain those same values after ManifestWork apply. Phase A shows Kubernetes accepts them on the same cluster; Phase B shows KubeStellar downsync currently does not.

### Screenshots / logs

Attach:

- `manual_tests/service_clusterip_nodeport_repro/sample_log.txt` (successful repro)
- `kubestellar-snapshot.tar.gz` (optional)

### Environment

- KubeStellar version: **0.29.0** (core-chart helm install)
- Kubernetes version: **1.36.1** (kindest/node:v1.36.1)
- Host OS: Linux (Kind on WSL2)

### Additional context

Same class of problem as other **late-binding / cluster-local** fields (PV `claimRef.uid`, HPA-driven replicas, etc.): hub wrap shape does not match what a single-cluster apply produces, even when ManifestWork reports success.

Manual repro bundle mirrors the static PV layout (#3959 / `pvc_static_bind_lost_repro`): **same yaml, same edge, direct apply vs downsync**.

Related Ursa variants (same wrap family): `ursa-bp-nodeport-sticky-manualport`, `ursa-bp-nodeport-localized` (also drops traffic policies), `ursa-bp-ingress` (Ingress healthy; static ClusterIP backend drifts).
