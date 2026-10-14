# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`[Bug]: Pod image updates are not synced in either direction (hub updates never delivered, edge drift never reverted)`

File AFTER the Service edge-drift issue and replace #XXXX below with its number.

Related but distinct from:
- #XXXX (Service edge drift: same promise, one direction; here both directions break)
- https://github.com/kubestellar/kubestellar/issues/3978 (transform/strip discussion)

Paste below the line into a new issue. After you reproduce, attach
`kubestellar-snapshot.tar.gz` as in the previous issues.

---

### Describe the bug

Hi KubeStellar Maintainers,

We noticed another behaviour we believe to be a bug, similar in spirit to #XXXX (Service edge drift): it also breaks the documented promise that the work agent runs "a reconciler to ensure the actual state matches the desired state" and that KubeStellar "continually strives to achieve what you are currently asking it to do" — this time for Pods, and in both directions.

Pods are mostly immutable, however there are a few fields Kubernetes allows updating in place: the `image` of containers and init containers, `spec.activeDeadlineSeconds`, and additions to `spec.tolerations`.

We noticed that when a downsynced Pod is updated on the WDS (for example a new `image`), the hub accepts the update, but the edge never receives it. The Pod on every edge keeps running the old image forever, while the ManifestWork stays `Applied=True / Available=True`.

The drift also occurs the other way. When we edit the image of the Pod directly on the edge, acting as a third party, the hub never reverts the change. So for a Pod the one field a user can legally update is not synced in either direction: hub updates are not delivered, edge drift is not corrected, and no signal is raised anywhere.

We understand one might say Pods are unlikely to be created directly and that Deployments are what users would normally downsync. But deploying a bare Pod is still possible and supported (quick one-off actions, debug pods, pinned singletons), and the documentation's promise ("create, read, update, delete ... as you like") makes no exception for Pods. If a bare Pod is downsynced and a third party changes its image on the edge, the hub remains blind to the change and does not revert it. Our resource can easily be running a completely different image than the one we declared, and this is invisible to us.

### Details

What we are seeing is that for a downsynced Pod, the only fields a user can legally update are not synced at all: a hub image update is accepted by the WDS but never delivered to any edge, and an edge image change is never noticed or reverted, while the ManifestWork stays `Applied=True / Available=True` in both cases. This breaks the same reconciliation promise we reported in #XXXX, this time in both directions.

From our debugging, this was the behaviour we noticed:

**The mechanism.** The apply function the work agent uses for Pods compares and writes **metadata only**. The code comment in [core.go](https://github.com/openshift/library-go/blob/master/pkg/operator/resource/resourceapply/core.go) says it outright:

```go
// ApplyPod merges objectmeta, does not worry about anything else
```

That one line explains both directions. When the hub updates the image, the ManifestWork payload changes and the agent does reconcile, but the reconcile only ensures metadata, so the new spec is never written to the edge. When a third party changes the image on the edge, nothing the check looks at has moved, so the agent concludes there is nothing to do. A Deployment, by contrast, has no special casing: it falls to the agent's generic apply path, which compares everything outside metadata and status, so Deployment updates are delivered and Deployment edge drift is reverted.

**The history.** `ApplyPod` was born in openshift/library-go [PR #145](https://github.com/openshift/library-go/pull/145) (2018, [commit 3c7238a1](https://github.com/openshift/library-go/commit/3c7238a1)) for OpenShift's static-pod machinery: it launches run-once installer pods, where each new revision is a new pod with a new name. In that model, updating an existing Pod's spec is a situation that never occurs, so metadata-only was the correct behaviour for its job. Unlike the Service case (see the history in #XXXX), this was not even a shortcut; it was right code for a different job. The work agent now uses it for user workloads, where in-place image updates are legal in Kubernetes and promised by the documentation ("create, read, update, delete ... as you like").

**Why metadata-only exists, and the actual fix.** The reason for `ApplyPod`'s conservatism is to avoid cases of the agent reverting changes made by the cluster itself, like the scheduler assigning `nodeName` or admission injecting tolerations: a full-compare rewrite would try to remove those values (the WDS copy does not have them), Pod spec is immutable beyond the few fields above, and every apply would be refused, leaving the ManifestWork at `Applied=False` forever. So the protection is real, but it is achieved by giving up on the spec entirely, which is why the one field a user can legally update is abandoned along with the fields the cluster owns.

However, the fix for this is Server-Side Apply: per-field ownership gives the protection without the abandonment. The hub declares `image`, so image updates are delivered and image drift is reverted; the hub never declares `nodeName` or the injected tolerations, so the cluster's own values are respected. The ManifestWork API already supports `updateStrategy: ServerSideApply` ([work/v1 types at v0.15.0](https://github.com/open-cluster-management-io/api/blob/v0.15.0/work/v1/types.go#L157), the OCM API version KubeStellar v0.29.0 pins), and the Server-Side Apply direction in PR [#3968](https://github.com/kubestellar/kubestellar/pull/3968) points the same way.

### Steps To Reproduce

Self-contained bundle (same layout as the previous issues):

`manual_tests/pod_image_sync_repro/`

Test folder: [pod_image_sync_repro](https://github.com/munachimso-victor/UrsaPublic/tree/main/manual_tests/pod_image_sync_repro)

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** downsync a bare Pod and a Deployment (the control), both `nginx:1.27.1`, to `edge-1`. Phase A: update both images on the hub — the Deployment's lands on the edge, the Pod's never does. Phase B: change both images on the edge — the Deployment is reverted at the next resync, the Pod keeps our drift forever. The ManifestWork stays green throughout. (The agent's periodic resync is ~5 minutes; waits are sized to span two resyncs wherever we claim "never".)

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/pod_image_sync_repro
chmod +x install_requirements.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar cluster setup

```bash
cd /path/to/manual_tests/pod_image_sync_repro
export KUBECONFIG=~/.kube/kubeflex
./setup_kubestellar.sh

kubectl --context edge-1 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-2 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-3 apply -f fix-klusterlet-rbac.yaml
```

#### Step 3 — Downsync the seed

```bash
export KUBECONFIG=~/.kube/kubeflex
cd /path/to/manual_tests/pod_image_sync_repro

kubectl --context wds1 apply -f pod_seed.yaml
kubectl --context wds1 apply -f pod_policy.yaml
sleep 60

kubectl --context edge-1 get pod,deploy -n ursa-namespace-template
```

Pod and Deployment exist on `edge-1`, both `nginx:1.27.1`.

#### Step 4 — Phase A: update both images on the HUB

```bash
kubectl --context wds1 patch deploy -n ursa-namespace-template ursa-deployment-template \
  --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.27.2"}]'
kubectl --context wds1 patch pod -n ursa-namespace-template ursa-pod-template \
  --type json -p '[{"op":"replace","path":"/spec/containers/0/image","value":"nginx:1.27.2"}]'

sleep 720   # spans two ~5-min resyncs

kubectl --context edge-1 get deploy -n ursa-namespace-template ursa-deployment-template \
  -o jsonpath='deploy image={.spec.template.spec.containers[0].image}{"\n"}'
kubectl --context edge-1 get pod -n ursa-namespace-template ursa-pod-template \
  -o jsonpath='pod image={.spec.containers[0].image}{"\n"}'
```

**Bug (hub direction):** the edge Deployment shows `nginx:1.27.2` (control delivered) while the edge Pod still shows `nginx:1.27.1` — the hub's Pod update never arrives, at any resync.

#### Step 5 — Phase B: change both images on the EDGE

```bash
kubectl --context edge-1 patch deploy -n ursa-namespace-template ursa-deployment-template \
  --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.25.0"}]'
kubectl --context edge-1 patch pod -n ursa-namespace-template ursa-pod-template \
  --type json -p '[{"op":"replace","path":"/spec/containers/0/image","value":"nginx:1.25.0"}]'

sleep 720   # spans two ~5-min resyncs

kubectl --context edge-1 get deploy -n ursa-namespace-template ursa-deployment-template \
  -o jsonpath='deploy image={.spec.template.spec.containers[0].image}{"\n"}'
kubectl --context edge-1 get pod -n ursa-namespace-template ursa-pod-template \
  -o jsonpath='pod image={.spec.containers[0].image}{"\n"}'
```

**Bug (edge direction):** the edge Deployment is reverted to the hub's value (control) while the edge Pod keeps `nginx:1.25.0` forever.

#### Step 6 — The ManifestWork is green throughout

```bash
kubectl --context its1 -n edge-1 get manifestworks -o yaml | grep -B1 -A2 'type: Applied'
```

`Applied=True / Available=True` on every manifest: no signal for either direction of the Pod mismatch.

Snapshot:

```bash
export KUBECONFIG=~/.kube/kubeflex
bash <(curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/refs/heads/main/scripts/kubestellar-snapshot.sh) \
  -K ~/.kube/kubeflex -V -Y -L
```

### Expected Behavior

The mutable Pod fields (`image`, `activeDeadlineSeconds`, toleration additions) are desired state like any other: hub updates should be delivered, and edge drift should be reverted or at minimum reported instead of `Applied=True / Available=True`.

Per-field ownership (`updateStrategy: ServerSideApply`, already in the ManifestWork API) gives this without fighting cluster-owned fields like `nodeName`.

### Additional Context

Observed on KubeStellar v0.29.0 (hub and edges on Kubernetes v1.36.1), but nothing here is version-specific.

In our automated runs the hub-direction failure appeared in 217 cases across ~26 Pod-bearing seeds (in-place image updates on the WDS never delivered), and the edge-direction drift persisted in every Pod seed's edge-perturbation modes, with the oracle cluster (same yaml applied directly) following the hub while the edges kept our values.
