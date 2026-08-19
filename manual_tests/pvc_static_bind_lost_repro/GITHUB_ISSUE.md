# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`[Bug]: Static PV/PVC bind fails — hub clears claimRef.uid absent on WDS`

Related but distinct from:
- https://github.com/kubestellar/kubestellar/issues/3855 (storageClassName null)
- https://github.com/kubestellar/kubestellar/issues/3959 (volumeName null / "" — edge binder fills volumeName, hub fights immutable spec)
- https://github.com/fluxcd/flux2/issues/2250 (same claimRef.uid stripping pattern in GitOps)

Paste below the line into a new issue. After you reproduce, attach
`kubestellar-snapshot.tar.gz` as in those issues.

---

### Describe the bug

Hi KubeStellar Maintainers,

We came across another issue with KubeStellar and how it handles PersistentVolumeClaim / PersistentVolume interactions.

Previous issues [#3855](https://github.com/kubestellar/kubestellar/issues/3855) and [#3959](https://github.com/kubestellar/kubestellar/issues/3959) showed how the hub can conflict with **fields edge controllers populate after create**. Here we see a case where downsync disagrees with how Kubernetes **statically** binds PVs and PVCs.

KubeStellar requires edge resource config to match hub desired state. That breaks for late-binding fields. For static PV/PVC pairing you list the PVC on the PV; on a normal cluster the PV binder adds the PVC uid and resourceVersion to `spec.claimRef`. WDS has no binder, so that data never exists on the hub. When downsync applies the hub PV to the edge, the spoke binder **does** attach the PVC uid — but KubeStellar then **immediately clears** `claimRef.uid` / `resourceVersion` to match hub. The PV and PVC never stay bound; the PV remains **Available** and the PVC **Lost**.

Unlike #3959, our seed already sets `PVC.spec.volumeName` — there is no volumeName apply fight. The failure is on the PV side: hub re-applies a `claimRef` without binder-owned identity right after the spoke binder writes it. (Same pattern as [fluxcd/flux2#2250](https://github.com/fluxcd/flux2/issues/2250).)

### Details

On a normal single cluster, the same seed binds cleanly:

1. PVC is created with `volumeName: ursa-csipv-template`.
2. PV is created with `claimRef: { name, namespace }` only (no uid in the YAML).
3. The **PV binder** runs locally and writes `claimRef.uid` + `claimRef.resourceVersion` on the PV to match **that cluster's PVC uid**.
4. PV → `Bound`, PVC → `Bound`.

Under KubeStellar downsync:

1. WDS has **no PV binder** → hub PV `claimRef` stays **name + namespace only** (no uid).
2. Transport wraps **live WDS PV** into ManifestWork → edge desired state also has **no `claimRef.uid`**.
3. Work-agent applies hub desired state → spoke PV is created with uid absent.
4. Spoke **PV binder runs** and attaches the spoke PVC **uid** (and `resourceVersion`) to `spec.claimRef` on the PV.
5. KubeStellar **reacts immediately** and clears `claimRef.uid` / `resourceVersion` on the edge PV to match hub.
6. The bind never completes — PV stays **`Available`**, PVC stays **`Lost`**.

| | WDS / wrap desired `claimRef` | Oracle (kubectl apply, same seed) | Edge (downsync) |
|---|---|---|---|
| `name` / `namespace` | yes | yes | yes |
| `uid` | **absent** (no hub binder) | **set** (local binder) | **absent** (cleared after binder writes it) |
| `resourceVersion` | **absent** | **set** | **absent** |
| PV `status.phase` | Pending / n/a | **Bound** | **Available** |
| PVC `status.phase` | Pending / n/a | **Bound** | **Lost** |

ManifestWork may show `Applied=True` — unlike #3959 there is no immutable-field apply fight on the PVC. The spoke binder runs, but hub downsync immediately clears the uid it wrote, so the pair never stays bound.

**Ursa twin evidence** (`ursa-bp-csipv` original):

- `spec.claimRef.uid`: edge **absent**, oracle **`cc88b6cf-…`**
- `spec.claimRef.resourceVersion`: edge **absent**, oracle **`10070`**
- PVC: edge **`Lost`**, oracle **`Bound`**

What should downsync do for binder-owned PV fields? Options we see:

- **Stop enforcing** hub-absent `spec.claimRef.uid` / `resourceVersion` on the spoke (ignore-fields / SSA / omit from wrap), so the **spoke binder** can populate them locally, or
- After PVC create on the spoke, rewrite `claimRef.uid` on the PV to the **spoke PVC uid** before or instead of re-applying hub shape.

### Steps To Reproduce

Self-contained bundle (same layout as #3959):

`manual_tests/pvc_static_bind_lost_repro/`

Test folder: [pvc_static_bind_lost_repro](https://github.com/munachimso-victor/UrsaPublic/tree/main/manual_tests/pvc_static_bind_lost_repro)

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** use the **same WEC (`edge-1`)** and the **same `pvc_seed.yaml`** twice — first applied **directly** on the edge (control), then after cleanup applied **via WDS** downsync (bug).

**Ursa automated hits:**

- `tests/all_baselines_10shards/shard4/run_baseline_reset_always/testcase_005_ursa-bp-csipv_original.txt`
- `tests/all_baselines_10shards/shard4/run_baseline_reset_always/testcase_013_ursa-bp-pvc_original.txt`

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/pvc_static_bind_lost_repro
chmod +x install_requirements.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar cluster setup

```bash
cd /path/to/manual_tests/pvc_static_bind_lost_repro
export KUBECONFIG=~/.kube/kubeflex
./setup_kubestellar.sh

kubectl --context edge-1 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-2 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-3 apply -f fix-klusterlet-rbac.yaml
```

#### Step 3 — Phase A: apply seed directly on `edge-1` (control — bind works)

```bash
export KUBECONFIG=~/.kube/kubeflex
cd /path/to/manual_tests/pvc_static_bind_lost_repro

kubectl --context edge-1 apply -f pvc_seed.yaml
sleep 15

kubectl --context edge-1 get pv ursa-csipv-template \
  -o jsonpath='PV phase={.status.phase} claimRef.uid={.spec.claimRef.uid}{"\n"}'
kubectl --context edge-1 get pvc -n ursa-namespace-template ursa-pvc-template \
  -o jsonpath='PVC phase={.status.phase} uid={.metadata.uid}{"\n"}'
kubectl --context edge-1 get pv ursa-csipv-template -o yaml | grep -A8 'claimRef:'
```

**Phase A success:** PV **`Bound`**, PVC **`Bound`**, `spec.claimRef.uid` **set** (matches PVC `metadata.uid`).

#### Step 4 — Clean up `edge-1` before hub push

```bash
export KUBECONFIG=~/.kube/kubeflex
kubectl --context edge-1 delete -f pvc_seed.yaml --ignore-not-found --wait=false
sleep 45
kubectl --context edge-1 get pv ursa-csipv-template 2>&1   # expect NotFound
```

#### Step 5 — Phase B: same yaml via WDS + BindingPolicy (bug)

```bash
export KUBECONFIG=~/.kube/kubeflex
kubectl --context wds1 apply -f pvc_seed.yaml
kubectl --context wds1 apply -f pvc_policy.yaml
sleep 60
```

#### Step 6 — Verify Phase B on the same `edge-1`

```bash
export KUBECONFIG=~/.kube/kubeflex

echo '=== WDS PV (no hub binder) ==='
kubectl --context wds1 get pv ursa-csipv-template \
  -o jsonpath='claimRef.uid={.spec.claimRef.uid}{"\n"}'

echo '=== edge-1 after downsync ==='
kubectl --context edge-1 get pv ursa-csipv-template \
  -o jsonpath='PV phase={.status.phase} claimRef.uid={.spec.claimRef.uid}{"\n"}'
kubectl --context edge-1 get pvc -n ursa-namespace-template ursa-pvc-template \
  -o jsonpath='PVC phase={.status.phase}{"\n"}'

kubectl --context its1 -n edge-1 get manifestworks -o yaml | \
  grep -B2 -A10 'claimRef:'
```

**Phase B success (bug reproduced):**

- Same cluster that was **`Bound`** in Phase A is now **`Available` / `Lost`**
- Edge PV `spec.claimRef.uid` **empty**
- Wrapped PV `claimRef` has name + namespace only (no uid)

Snapshot after Step 6:

```bash
export KUBECONFIG=~/.kube/kubeflex
bash <(curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/refs/heads/main/scripts/kubestellar-snapshot.sh) \
  -K ~/.kube/kubeflex -V -Y -L
```

### Expected Behavior

Downsync should not clear binder-owned fields the hub never had:

- Do **not** re-apply hub-absent `spec.claimRef.uid` / `resourceVersion` over what the spoke PV binder just wrote, or
- Omit those paths from the wrap / ignore them in apply strategy so the spoke binder can finish the bind.

Static prebind PV/PVC should end with PV **`Bound`** and PVC **`Bound`** on the WEC, not PV **`Available`** and PVC **`Lost`** because hub immediately cleared `claimRef.uid`.

### Additional Context

Observed on KubeStellar **v0.29.0** / **v1.36.1** and default pins in Ursa 10-shard originals (`reset_always` and `reset_on_failure`).

Kitchen-sink policies that include this PV/PVC (Deployment, CronJob, ultimate-*) show the same PVC `Lost` and follow-on pod unschedulable.
