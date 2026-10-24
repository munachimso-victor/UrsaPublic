# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`bug: a label removed on the WDS is never removed on the spokes`

Related:
- https://github.com/kubestellar/kubestellar/issues/4006 (edge drift on delivered fields; this issue is the hub-side metadata face of the same reconciliation gap)

Paste below the line into a new issue. After you reproduce, attach
`kubestellar-snapshot.tar.gz` as in the previous issues.

---

### Describe the bug

Hi KubeStellar Maintainers,

We noticed a behaviour we believe to be a bug, concerning object metadata labels.

KubeStellar's goal is continual reconciliation of the delivered objects: "maintenance … means that KubeStellar continually strives to achieve what you are currently asking it to do" ([user-guide-intro.md](https://github.com/kubestellar/kubestellar/blob/v0.29.0/docs/content/direct/user-guide-intro.md?plain=1#L46)).

By default, the OCM work agent underneath was built for a slightly different purpose: a transport serving many operators managing resources on the same clusters. So that one operator does not overwrite another's actions, metadata labels are merged, not replaced ("Labels and Annotations will be merged from required to the existing resource" — [OCM enhancement 47](https://github.com/open-cluster-management-io/enhancements/tree/main/enhancements/sig-architecture/47-manifestwork-updatestrategy)).

This tweak for metadata is nice and handy for KubeStellar: a cluster-management controller on the edge can add its own labels and annotations to delivered objects without triggering the hub to overwrite them. However, we noticed an issue when trying to delete a label from the spokes: the hub is unable to do so.

A merge that never deletes keys has no way to say "this key is gone" — so through KubeStellar the hub can add labels and change their values on the spokes, but can never remove one. The removal is accepted on the WDS, every spoke keeps the label forever, and the ManifestWork stays `Applied=True / Available=True` throughout. We found this with labels; it applies equally to annotations.

### Details

**Merging is not the problem in itself.** Kubernetes' own `kubectl apply` is also a merge, and it removes labels correctly, because it is a **3-way** merge: it diffs the new manifest against the last-applied manifest (kept in the `kubectl.kubernetes.io/last-applied-configuration` annotation) and the live object. A key present in last-applied but absent from the new manifest was deleted by the user, so the patch removes it; a key only on the live object was never the applier's, and survives. Three-way merging preserves other actors' metadata and delivers removals.

**The work agent's merge is 2-way, so a removal is invisible.** Both apply paths merge labels and annotations with [`MergeMap`](https://github.com/openshift/library-go/blob/4bb4238aef81/pkg/operator/resource/resourcemerge/object_merger.go#L107-L132). It sees only the desired manifest and the live object: with no record of what was previously applied, a removed key looks the same as a key the hub never owned, so nothing is ever deleted.

**A 2-way merge at this level therefore needs an explicit way to translate a deletion to the spokes.** OpenShift, which library-go was written for, resolves this in memory: an operator marks the key with a trailing dash in the desired map (`"foo-"`), and the merge translates it into a deletion of `foo` on the live object.

**In the ManifestWork path, no such translation exists.** The WDS and ITS should be able to have a convention to communicate a label removal to the work agent. The `"foo-"` convention OpenShift uses cannot be replicated here, because that communication happens in memory: `"foo-"` is an illegal label key to Kubernetes, so it cannot be stored on a WDS object nor inside a ManifestWork manifest (we verified both: the WDS rejects it with `Invalid value: "foo-": name part must … end with an alphanumeric character`, and OCM's ManifestWork admission webhook rejects the same key inside `spec.workload.manifests`). We would recommend either a removal translation along these lines, or a different update method for object metadata than the current 2-way merge.

### Steps To Reproduce

Self-contained bundle (same layout as the previous issues):

`manual_tests/label_removal_repro/`

Test folder: [label_removal_repro](https://github.com/munachimso-victor/UrsaPublic/tree/main/manual_tests/label_removal_repro)

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** Phase A is the control — add, update and remove a label and an annotation **directly on a plain edge cluster**: all three operations work; KubeStellar is not involved. Phase B repeats the same three operations **from the WDS** on a downsynced ConfigMap: the create is delivered, the value update is delivered (we observed it land within 5 s), the removal is never delivered — the spoke keeps the label and the annotation past two ~5-minute agent resyncs while the ManifestWork stays green. (Cluster names in this bundle are `repro-hub` / `repro-1/2/3` on port 9450, so it can run next to a default kubeflex install.)

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/label_removal_repro
chmod +x install_requirements.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar cluster setup

```bash
export KUBECONFIG=~/.kube/repro
./setup_kubestellar.sh

kubectl --context repro-1 apply -f fix-klusterlet-rbac.yaml
kubectl --context repro-2 apply -f fix-klusterlet-rbac.yaml
kubectl --context repro-3 apply -f fix-klusterlet-rbac.yaml
```

#### Step 3 — Phase A: the control, directly on a plain edge (no KubeStellar)

```bash
kubectl --context repro-1 create cm ctl-cm -n default --from-literal=k=v

# A1 create a label and an annotation
kubectl --context repro-1 label cm ctl-cm -n default team=blue remove-me=yes
kubectl --context repro-1 annotate cm ctl-cm -n default note=hello

# A2 update the label value
kubectl --context repro-1 label cm ctl-cm -n default team=red --overwrite

# A3 delete the label and the annotation
kubectl --context repro-1 label cm ctl-cm -n default remove-me-
kubectl --context repro-1 annotate cm ctl-cm -n default note-

kubectl --context repro-1 get cm ctl-cm -n default \
  -o jsonpath='labels={.metadata.labels} annotations.note={.metadata.annotations.note}'
```

All three operations land: the final line shows `labels={"team":"red"}` and no annotation.

#### Step 4 — Phase B1: create through the hub

```bash
kubectl --context wds1 apply -f labeldemo_seed.yaml
kubectl --context wds1 apply -f labeldemo_policy.yaml
sleep 60

kubectl --context repro-2 get cm demo-cm -n label-demo \
  -o jsonpath='labels={.metadata.labels} annotations.note={.metadata.annotations.note}'
```

Delivered: `labels={"remove-me":"yes","team":"blue"} annotations.note=hello`.

#### Step 5 — Phase B2: update the label value on the hub

```bash
kubectl --context wds1 label cm demo-cm -n label-demo team=red --overwrite
sleep 60

kubectl --context repro-2 get cm demo-cm -n label-demo -o jsonpath='labels={.metadata.labels}'
```

Delivered: `labels={"remove-me":"yes","team":"red"}` (we observed it within 5 s).

#### Step 6 — Phase B3: remove the label and the annotation on the hub (the bug)

```bash
kubectl --context wds1 label cm demo-cm -n label-demo remove-me-
kubectl --context wds1 annotate cm demo-cm -n label-demo note-
kubectl --context wds1 get cm demo-cm -n label-demo \
  -o jsonpath='labels={.metadata.labels} annotations.note={.metadata.annotations.note}'

sleep 720   # spans two ~5-min agent resyncs

# what the SPOKE actually holds: its label map and the note annotation
kubectl --context repro-2 get cm demo-cm -n label-demo \
  -o jsonpath='labels={.metadata.labels} annotations.note={.metadata.annotations.note}'
# what the TRANSPORT claims: our delivery envelopes' Applied/Available status on the ITS
kubectl --context its1 get manifestwork -n repro-2 \
  -l transport.kubestellar.io/originOwnerReferenceBindingKey=label-removal-repro \
  -o custom-columns='NAME:.metadata.name,APPLIED:.status.conditions[?(@.type=="Applied")].status,AVAILABLE:.status.conditions[?(@.type=="Available")].status'
```

**Bug:** the WDS shows `labels={"team":"red"}` and no annotation, while `repro-2` still shows `labels={"remove-me":"yes","team":"red"} annotations.note=hello` after 720 s, and the ManifestWork reports `Applied=True / Available=True`. The removal is never delivered and nothing reports the difference.

### Expected behavior

Removing a label or annotation from a downsynced object on the WDS removes it on the spokes, the same way adding one or changing its value does — or, failing that, something reports that the desired and actual state differ.

### Environment

- KubeStellar v0.29.0 (kubeflex-hosted WDS v1.29.9, ITS k3s, edges kind v1.37.0)
- Observed on ConfigMaps here; in our fleet testing the same behaviour appears on every labeled kind we exercised (~27 built-in kinds), in fully connected operation.

`kubestellar-snapshot.tar.gz` attached after reproduction.
