# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`[Bug]: Service edge drift on delivered fields is never reconciled (only selector and type are defended)`

Related but distinct from:
- https://github.com/kubestellar/kubestellar/issues/3978 (stripped pins — fields that never travel; this report is about fields that DO travel)
- the healthCheckNodePort issue (transform incoherence — fill in number once filed)

Paste below the line into a new issue. After you reproduce, attach
`kubestellar-snapshot.tar.gz` as in the previous issues.

---

### Describe the bug

Hi KubeStellar Maintainers,

We noticed a behaviour we believe to be a bug and we want to hear what you think.

Our bug report is hinged on some claims we noticed KubeStellar makes in its documentation:
The work agent runs "a reconciler to ensure the actual state matches the desired state", and the user guide says KubeStellar "continually strives to achieve what you are currently asking it to do".

We found that for a Service, KubeStellar does not reconcile edge drift on the fields it delivers (it does this for a Deployment and some other kinds).
By edge drift we mean a case where a third party updates an object managed by the hub on the edge. The expectation is for the hub to revert the edge back to the known desired state.

We downsync a Service from the WDS to the edges, then change one of its delivered spec fields directly on the edge, acting as a third party drifting the workload. For example, on an `ExternalName` Service we change `spec.externalName`, silently repointing the Service at a completely different backend.

Nothing ever corrects it. The edge keeps our drifted value forever, the hub keeps the desired one, and the ManifestWork reports `Applied=True / Available=True` the whole time. There is no signal anywhere that the edge no longer matches the desired state.

The same experiment on `spec.selector` or `spec.type` behaves correctly: the agent reverts the change at its next periodic resync (about 5 minutes in our setup). So the reconciliation is real but only covers those two fields. Everything else in a delivered Service spec (`ports`, `externalName`, `publishNotReadyAddresses`, `loadBalancerSourceRanges`, ...) is never compared against the live edge object.

The drift persists for as long as the hub object is unchanged. If the hub later updates any spec field of that Service, the full-spec rewrite flushes the edge drift as a side effect, which shows the correction is accidental, not reconciliation.

For a Deployment the same edge drift is detected and fixed, so this is a per-kind gap, not a general design decision.

Note that the fields we mention here do not include the fields stripped by the built-in Service transform (`externalTrafficPolicy`, `internalTrafficPolicy`, `sessionAffinity`, `clusterIP`, `nodePort`, ...). We understand that since KubeStellar strips those, it won't manage them if they change on the edge (that is a separate discussion, see #3978). This report is only about fields KubeStellar **does** deliver: they arrive once, and are then never reconciled.

### Details

The documentation claims we tested against:

> "a reconciler to ensure the actual state matches the desired state" — [architecture.md](https://github.com/kubestellar/kubestellar/blob/v0.29.0/docs/content/direct/architecture.md?plain=1#L231)

> "KubeStellar is eventually consistent: you can change your inputs as you like over time, and KubeStellar continually strives to achieve what you are currently asking it to do." — [user-guide-intro.md](https://github.com/kubestellar/kubestellar/blob/v0.29.0/docs/content/direct/user-guide-intro.md?plain=1#L46)

What we are seeing is a Service delivered by KubeStellar that an edge-side third party can then edit freely, with no correction and no signal. The drifted edge runs a different Service than the one the hub declares, indefinitely, while every status KubeStellar exposes stays green. Only `selector` and `type` are defended; the same edit on a Deployment is reverted.

From our debugging, this was the behaviour we noticed:

**The mechanism.** The work agent decides whether a delivered Service needs a write by checking three things: the edge object's `selector` (live compare), its `type` (live compare), and an annotation it stamped on the edge copy holding a hash of the hub's spec. The hash only moves when the hub's desired spec changes, so it answers "did the hub change?", never "does the edge still match?". An edge change to any other spec field touches none of the three checks, so the agent concludes there is nothing to do. A Deployment, by contrast, has no Service-style special casing: it falls to the agent's generic apply path, which compares everything outside metadata and status against the live edge object and re-applies on any difference, which is why Deployment edge drift is detected and fixed.

**The history.** The apply functions come from openshift/library-go, written for single-cluster OpenShift operators. For an object like Service, some spec fields are updated by the cluster itself (the apiserver allocates clusterIP and nodePorts), so the library could not tell an intended change from an illegitimate third-party one. The original author said so in the code when the function was born ([PR #10, 2018](https://github.com/openshift/library-go/pull/10)):

```go
// TODO, since this cannot determine whether changes are due to legitimate actors (api server)
//       or illegitimate ones (users), we cannot update
// TODO I've special cased the selector for now
```

Instead of solving that problem, the check was shrunk to the two fields users mainly touch, `selector` and `type` ([PR #115](https://github.com/openshift/library-go/pull/115) later taught the `type` compare about defaulting). In 2022, [PR #1367](https://github.com/openshift/library-go/pull/1367) added the spec-hash annotation so that any change **by the operator** is detected and pushed down, explicitly keeping "the existing heuristics of user changes (spec.type, spec.selector) in place". But a change on the cluster side still triggers nothing. The current write path's own comment ([core.go](https://github.com/openshift/library-go/blob/master/pkg/operator/resource/resourceapply/core.go)) says: "Stomp over any user *and* Kubernetes changes, hoping that Kubernetes will restore its values."

**Why it matters more here.** With this library adopted for multi-cluster, the operator is now the hub. Changes made by the hub are pushed to the edges, but changes made at the edge by a third party are not reconciled as the documentation promises, except on `selector` and `type`. In the single-cluster setting this shortcut was mostly harmless: the operator and its Service live on the same cluster, and third parties editing operator-owned objects are rare. In a multi-cluster setting, converging exactly this kind of third-party edge change is the core of the promise.

**A path to a fix.** The original problem, knowing a legitimate change from an illegitimate one, has since been addressed by Kubernetes itself: Server-Side Apply tracks per-field ownership in `managedFields`. And OCM has adopted it. The ManifestWork API that KubeStellar already generates supports `updateStrategy: ServerSideApply` ([work/v1 types at v0.15.0](https://github.com/open-cluster-management-io/api/blob/v0.15.0/work/v1/types.go#L157), the exact OCM API version KubeStellar v0.29.0 pins), where the hub ensures the fields it defines are maintained and consistent, while fields it did not define are free to be altered by the edge. Some of our previous reports point the same way: in #3960, #3959 and #3977 the agent fights fields the cluster fills in at runtime, and the Server-Side Apply direction already being explored in PR [#3968](https://github.com/kubestellar/kubestellar/pull/3968) would treat both those and this report with one mechanism: declared fields are enforced, undeclared fields are left to the cluster.

### Steps To Reproduce

Self-contained bundle (same layout as the previous issues):

`manual_tests/service_edge_drift_repro/`

Test folder: [service_edge_drift_repro](https://github.com/munachimso-victor/UrsaPublic/tree/main/manual_tests/service_edge_drift_repro)

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** downsync two Services (ClusterIP + ExternalName) and a Deployment to `edge-1`. Phase A (controls): drift `selector` on the Service and the image on the Deployment, both reverted, proving the reconciliation machinery works. Phase B (bug): the same style of edit on delivered Service fields stays drifted forever with the ManifestWork green.

The ClusterIP Service pins nothing, so none of the built-in transform stripping is involved in what we test.

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/service_edge_drift_repro
chmod +x install_requirements.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar cluster setup

```bash
cd /path/to/manual_tests/service_edge_drift_repro
export KUBECONFIG=~/.kube/kubeflex
./setup_kubestellar.sh

kubectl --context edge-1 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-2 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-3 apply -f fix-klusterlet-rbac.yaml
```

#### Step 3 — Downsync the seed

```bash
export KUBECONFIG=~/.kube/kubeflex
cd /path/to/manual_tests/service_edge_drift_repro

kubectl --context wds1 apply -f service_seed.yaml
kubectl --context wds1 apply -f service_policy.yaml
sleep 60

kubectl --context edge-1 get svc,deploy -n ursa-namespace-template
```

All three objects exist on `edge-1`; `ursa-externalname-template` has `externalName=backend.example.com`.

#### Step 4 — Phase A, control 1: drift a defended Service field (selector)

```bash
export KUBECONFIG=~/.kube/kubeflex

kubectl --context edge-1 patch svc -n ursa-namespace-template ursa-clusterip-auto-template \
  --type merge -p '{"spec":{"selector":{"ursa-workload":"tampered"}}}'
```

The revert happens at the agent's next periodic resync (about 5 minutes); we patch the Deployment too (Step 5) and then check both.

#### Step 5 — Phase A, control 2: the same edit on a Deployment

```bash
kubectl --context edge-1 patch deploy -n ursa-namespace-template ursa-deployment-template \
  --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.25.0"}]'

sleep 360   # span one ~5-minute resync

kubectl --context edge-1 get svc -n ursa-namespace-template ursa-clusterip-auto-template \
  -o jsonpath='selector={.spec.selector}{"\n"}'
kubectl --context edge-1 get deploy -n ursa-namespace-template ursa-deployment-template \
  -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'
```

**Controls succeed:** the selector is back to the hub's value (`ursa-workload: ultimate-test`) and the image is back to `nginx:1.27.1` — the reconciliation machinery works, driven by the periodic resync.

#### Step 6 — Phase B: drift delivered Service fields (the bug)

```bash
export KUBECONFIG=~/.kube/kubeflex

# headline: silently repoint the ExternalName Service at a different backend
kubectl --context edge-1 patch svc -n ursa-namespace-template ursa-externalname-template \
  --type merge -p '{"spec":{"externalName":"attacker.example.net"}}'

# second example: change a delivered port field on the ClusterIP Service
kubectl --context edge-1 patch svc -n ursa-namespace-template ursa-clusterip-auto-template \
  --type json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'

sleep 720   # spans two ~5-minute resyncs — wait as long as you like, it never corrects

kubectl --context edge-1 get svc -n ursa-namespace-template ursa-externalname-template \
  -o jsonpath='externalName={.spec.externalName}{"\n"}'
kubectl --context edge-1 get svc -n ursa-namespace-template ursa-clusterip-auto-template \
  -o jsonpath='targetPort={.spec.ports[0].targetPort}{"\n"}'

kubectl --context its1 -n edge-1 get manifestworks -o yaml | grep -A3 'type: Applied'
```

**Bug reproduced when:** `edge-1` still shows `externalName=attacker.example.net` and `targetPort=9999` after multiple resyncs, the WDS still declares `backend.example.com` / `8080`, and the ManifestWork is `Applied=True / Available=True` with no signal anywhere — the same style of edit that Phase A reverted at the first resync.

#### Step 7 — Optional: correction happens only by accident

```bash
kubectl --context wds1 patch svc -n ursa-namespace-template ursa-clusterip-auto-template \
  --type json -p '[{"op":"replace","path":"/spec/ports/0/port","value":81}]'
sleep 60

kubectl --context edge-1 get svc -n ursa-namespace-template ursa-clusterip-auto-template \
  -o jsonpath='port={.spec.ports[0].port} targetPort={.spec.ports[0].targetPort}{"\n"}'
```

`port=81` **and** `targetPort` back to `8080`: the drift survived every reconcile until an unrelated hub change happened to rewrite the whole spec.

Snapshot:

```bash
export KUBECONFIG=~/.kube/kubeflex
bash <(curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/refs/heads/main/scripts/kubestellar-snapshot.sh) \
  -K ~/.kube/kubeflex -V -Y -L
```

### Expected Behavior

Fields the hub delivers are desired state: an edge change to them should be reverted, the way `selector`/`type` and Deployment drift already are, or at minimum the divergence should be reported instead of `Applied=True / Available=True`.

The `updateStrategy: ServerSideApply` already available in the ManifestWork API is the principled path: enforce the fields the hub declares, leave the fields it did not declare to the edge.

### Additional Context

Observed on KubeStellar v0.29.0 (hub and edges on Kubernetes v1.36.1), but nothing here is version-specific.

In our automated runs this surfaced across every Service seed and disconnect/perturbation mode: the edge kept our drifted values for `ports[].targetPort`, `ports[].protocol`, `ports[].name`, `ports[].port`, `publishNotReadyAddresses` and `loadBalancerSourceRanges` while the oracle cluster (same yaml applied directly) followed the hub, with the connected runs proving network cuts are irrelevant.
