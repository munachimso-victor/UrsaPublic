# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`[Bug]: CSIDriver config updates are delivered as delete + re-create of the driver; edge drift on the same fields is invisible`

File AFTER the Service edge-drift and Pod image-sync issues; replace #XXXX
(Service drift) and #YYYY (Pod) below with their numbers.

Paste below the line into a new issue. After you reproduce, attach
`kubestellar-snapshot.tar.gz` as in the previous issues.

---

### Describe the bug

Hi KubeStellar Maintainers,

We noticed two behaviours with the CSIDriver kind that we believe to be bugs by KubeStellar's own standards (the documented promise that the work agent runs "a reconciler to ensure the actual state matches the desired state").

After downsyncing a CSIDriver object to the edges, we noticed the following:

**1. Edge drift is not reconciled.** Similar to the bugs we reported for Service (#XXXX) and Pod (#YYYY), third-party mutations of the object on the edge are never noticed or reverted by the agent. A CSIDriver's mutable config fields (`fsGroupPolicy`, `podInfoOnMount`, `storageCapacity`, `tokenRequests`, `requiresRepublish`, `seLinuxMount`) can all be changed on the edge and stay changed forever, while the ManifestWork reports `Applied=True / Available=True`. The hub is oblivious to the actual configuration running on the edge.

**2. In-place updates are delivered as delete + create.** We would refer to this as a misoperation. An update we make on the WDS as a legal in-place update (for example changing `storageCapacity`, mutable in Kubernetes since 1.23) is executed on every edge as a **delete of the CSIDriver followed by a re-create**. A one-line config change arrives as a storage driver outage: for a window the driver object does not exist on the edge (attach and mount decisions and the CSI sidecars that watch the object see it disappear), the object's identity changes (new uid, a delete event to every watcher), and if the delete stalls the edge is left with no driver at all. The behaviour is a workaround for CSIDriver immutability rules that Kubernetes relaxed in 1.23 and 1.30, so the agent is strictly more destructive than the platform requires. And while the blast radius here is a storage driver, the same update-becomes-delete+create pattern would be far more detrimental on other kinds handled this way.

### Details

The documentation claim we tested against, as in #XXXX and #YYYY:

> "a reconciler to ensure the actual state matches the desired state" — [architecture.md](https://github.com/kubestellar/kubestellar/blob/v0.29.0/docs/content/direct/architecture.md?plain=1#L231)

From our debugging, both behaviours have the same root: the function the work agent uses for CSIDriver, `ApplyCSIDriver` in library-go's resourceapply package ([storage.go](https://github.com/openshift/library-go/blob/master/pkg/operator/resource/resourceapply/storage.go)).

**The mechanism (both behaviours, one check).** `ApplyCSIDriver` never reads the edge object's spec to check that it matches what the hub says. It compares the agent's picture of the hub (a hash of the hub's spec that the agent stamped as an annotation on the edge copy at its last write) against the hub's current picture of itself (the hash of the spec it is being asked to apply now). Only when the hub's picture changes does the edge receive anything. This is the same design as the Service bug (#XXXX), but stricter: Service at least live-compares `selector` and `type`, while CSIDriver has no wiggle room at all — the spec of the live edge object is never consulted for any field.

- Behaviour 1 follows directly: a third-party edit on the edge changes nothing in the hash comparison (the annotation is untouched, the hub didn't move), so the agent concludes there is nothing to do, forever.
- Behaviour 2 is what happens when the hash finally does move: the code's reaction to any spec change is delete + create. The comment in storage.go says it outright:

> "Most CSIDriver fields are immutable. Any change to them should trigger Delete() + Create() calls."

**Why delete + create is there.** This is intentional in the code — for the environment it was written for. In a single-cluster OpenShift operator environment, the operator owns its own CSIDriver on the same cluster, and forcing a delete + re-create was the only way to "update" an object whose spec Kubernetes treated as immutable at the time. The code was not attempting to make single-cluster and multi-cluster interactions align; it was a workaround for its own cluster's validation rules. Two things have changed around it:

1. Kubernetes relaxed the immutability: `storageCapacity` became mutable in 1.23, and `fsGroupPolicy` and `podInfoOnMount` in 1.30 (from 1.30 only `attachRequired` and `volumeLifecycleModes` remain immutable) (`tokenRequests`, `requiresRepublish`, `seLinuxMount` are also mutable). The comment's premise is no longer true for the common config fields, so the agent is strictly more destructive than the platform requires — an update Kubernetes would accept in place is executed as an outage.
2. The function now runs as the apply engine of a multi-cluster system, where the delete + create happens on every subscribed edge, against a live storage driver, triggered by a one-line config change on the hub.

(See the history sections of #XXXX and #YYYY for the fuller lineage of these apply functions: single-cluster operator tooling, written per kind, each encoding the Kubernetes semantics of its day.)

**A path to a fix.** Per-field ownership resolves both behaviours at once: with Server-Side Apply, the hub's declared fields are enforced against the live edge object (behaviour 1 gone), mutable fields are updated in place, and a genuinely immutable conflict surfaces as a visible apply failure instead of a silent teardown (behaviour 2 gone). The ManifestWork API already supports `updateStrategy: ServerSideApply` ([work/v1 types at v0.15.0](https://github.com/open-cluster-management-io/api/blob/v0.15.0/work/v1/types.go#L157), the OCM API version KubeStellar v0.29.0 pins), and the Server-Side Apply direction in PR [#3968](https://github.com/kubestellar/kubestellar/pull/3968) points the same way.

### Steps To Reproduce

Self-contained bundle (same layout as the previous issues):

`manual_tests/csidriver_update_outage_repro/`

Test folder: [csidriver_update_outage_repro](https://github.com/munachimso-victor/UrsaPublic/tree/main/manual_tests/csidriver_update_outage_repro)

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** downsync one CSIDriver (the `my-storage.example.com` seed from our automated test generation, unchanged). Phase A: change `fsGroupPolicy` on the edge — never noticed across two resyncs, ManifestWork green. Phase B: change `storageCapacity` on the WDS (a legal in-place update, mutable since 1.23) — the edge executes delete + create, proven by the new `metadata.uid` and `creationTimestamp` and by a watch recording the `DELETED`/`ADDED` events; on the WDS the same patch was an in-place update with an unchanged uid. Phase B doubles as the aliveness control: the agent acts the moment the hub changes, so Phase A was a refusal to look, not a dead agent. (The agent's periodic resync is ~5 minutes; waits are sized to span two resyncs wherever we claim "never".)

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/csidriver_update_outage_repro
chmod +x install_requirements.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar cluster setup

```bash
cd /path/to/manual_tests/csidriver_update_outage_repro
export KUBECONFIG=~/.kube/kubeflex
./setup_kubestellar.sh

kubectl --context edge-1 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-2 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-3 apply -f fix-klusterlet-rbac.yaml
```

#### Step 3 — Downsync the seed

```bash
export KUBECONFIG=~/.kube/kubeflex
cd /path/to/manual_tests/csidriver_update_outage_repro

kubectl --context wds1 apply -f csidriver_seed.yaml
kubectl --context wds1 apply -f csidriver_policy.yaml
sleep 60

kubectl --context edge-1 get csidriver my-storage.example.com \
  -o jsonpath='fsGroupPolicy={.spec.fsGroupPolicy} uid={.metadata.uid} created={.metadata.creationTimestamp}{"\n"}'
```

The CSIDriver exists on `edge-1` with `fsGroupPolicy=File`. Record the uid and creationTimestamp; Phase B proves the outage with them.

#### Step 4 — Phase A: behaviour 1 — drift `fsGroupPolicy` on the EDGE

```bash
kubectl --context edge-1 patch csidriver my-storage.example.com \
  --type merge -p '{"spec":{"fsGroupPolicy":"None"}}'

sleep 720   # spans two ~5-min resyncs

kubectl --context edge-1 get csidriver my-storage.example.com \
  -o jsonpath='fsGroupPolicy={.spec.fsGroupPolicy} uid={.metadata.uid}{"\n"}'
kubectl --context wds1 get csidriver my-storage.example.com \
  -o jsonpath='fsGroupPolicy={.spec.fsGroupPolicy}{"\n"}'
kubectl --context its1 -n edge-1 get manifestworks -o yaml | grep -B1 -A2 'type: Applied' | head -8
```

**Bug 1 reproduced when:** the edge keeps `fsGroupPolicy=None` across resyncs (same uid — no write of any kind), the WDS declares `File`, and the ManifestWork is `Applied=True / Available=True`.

#### Step 5 — Phase B: behaviour 2 — a legal in-place update on the HUB becomes delete + create

```bash
# a watch that records event types (DELETED / ADDED)
timeout 120 kubectl --context edge-1 get csidriver --watch --output-watch-events \
  -o custom-columns='EVENT:.type,NAME:.object.metadata.name,UID:.object.metadata.uid' &

sleep 2
# the hub update: in-place, legal since k8s 1.23
kubectl --context wds1 patch csidriver my-storage.example.com \
  --type merge -p '{"spec":{"storageCapacity":false}}'
sleep 110

kubectl --context edge-1 get csidriver my-storage.example.com \
  -o jsonpath='storageCapacity={.spec.storageCapacity} uid={.metadata.uid} created={.metadata.creationTimestamp}{"\n"}'
```

**Bug 2 reproduced when:** the watch printed `DELETED` then `ADDED` for `my-storage.example.com`, the uid and creationTimestamp differ from Step 3, and `storageCapacity=false` — the update did arrive, as an outage. (On the WDS the same patch was a plain in-place update with an unchanged uid. Note it also replaced Phase A's drift: correction by replacement, not reconciliation.)

#### Step 6 — The ManifestWork is green throughout

```bash
kubectl --context its1 -n edge-1 get manifestworks -o yaml | grep -B1 -A2 'type: Applied' | head -8
```

Snapshot:

```bash
export KUBECONFIG=~/.kube/kubeflex
bash <(curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/refs/heads/main/scripts/kubestellar-snapshot.sh) \
  -K ~/.kube/kubeflex -V -Y -L
```

### Expected Behavior

Behaviour 1: edge changes to delivered fields should be reverted or at minimum reported instead of `Applied=True / Available=True`.

Behaviour 2: an update that is legal in place (`fsGroupPolicy`, `podInfoOnMount`, `storageCapacity`, `tokenRequests`, `requiresRepublish`, `seLinuxMount`) should be applied in place, preserving object identity. Delete + create should be at most a last resort for genuinely immutable conflicts (`attachRequired`, `volumeLifecycleModes`), and loud when it happens.

Per-field ownership (`updateStrategy: ServerSideApply`, already in the ManifestWork API) gives both.

### Additional Context

Observed on KubeStellar v0.29.0 (automated runs: hub and edges on Kubernetes v1.36.1; this manual setup: kubeflex WDS on v1.29.9, edges on v1.37.0).

One wrinkle worth noting: the WDS's own Kubernetes version gates which updates a user can even express. Our kubeflex WDS runs 1.29, where `fsGroupPolicy` is still immutable, so the hub apiserver refuses that patch before KubeStellar is involved; `storageCapacity` (mutable since 1.23) goes through everywhere, which is why the repro uses it. The delete + create delivery is the agent's choice regardless of version.

In our automated runs (kind set 06, the `my-storage.example.com` seed): edge drift on `fsGroupPolicy`/`podInfoOnMount`/`storageCapacity` was never reverted in any mode; hub-side spec changes were delivered as delete + re-create; and in one observed half-heal the agent restored a tampered label (the metadata path) while leaving the spec drift in place (the hash path) — the two code paths visible in a single case.
