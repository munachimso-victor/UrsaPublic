# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`bug: a Pod pinned to a node of the target cluster can never be deleted through the WDS`

Paste below the line into a new issue. After you reproduce, attach
`kubestellar-snapshot.tar.gz` as in the previous issues.

---

### Describe the bug

Hi KubeStellar Maintainers,

We noticed a behaviour we believe to be a bug, concerning Pods pinned to a node.

In Kubernetes, it is a common practice to pin a workload to a specific node (`spec.nodeName`). When we try this with KubeStellar we run into issues. Running the workload works normally: we downsync a Pod pinned to a named node of the target cluster, and the edge runs it fine. But when we try to **delete** it, the Pod on the hub gets stuck in `Terminating` forever. Because the object never actually leaves the WDS, the ManifestWork is never deleted either — we verified the spoke's AppliedManifestWork still lists the Pod as an applied resource well after the delete — so every spoke keeps running the Pod indefinitely. The delete is accepted, nothing completes, and nothing reports an error.

Related bug: #3964 is the edge-side face of node-pinned Pods (a Pod naming a node that does not exist on the edge loops in create/delete ping-pong); this issue is the hub-side face.

### Details

**The WDS is designed as a dumbed-down apiserver.** Referencing KubeStellar documentation: a Space "behaves like a Kubernetes kube-apiserver (including the persistent storage behind it) and the subset of controllers in the kube-controller-manager that are concerned with API machinery generalities (not management of containerized workloads)" ([architecture.md](https://github.com/kubestellar/kubestellar/blob/v0.29.0/docs/content/direct/architecture.md?plain=1#L8)); the WDS "stores the definitions of workloads in their native Kubernetes format" ([wds.md](https://github.com/kubestellar/kubestellar/blob/v0.29.0/docs/content/direct/wds.md?plain=1#L14)).

**The gap: Pod graceful deletion is not a controller, it lives inside the apiserver itself.** Deleting a Pod with `spec.nodeName` set only marks it: the apiserver sets a deletion timestamp and waits for that node's kubelet to confirm shutdown. The WDS enforces this on the stored Pod too. No kubelet will ever talk to the WDS, so the Pod stays in `Terminating` forever.

**The compensating machinery is exactly what the design removes, and removing it is correct.** On a real cluster, the Pod garbage collector in kube-controller-manager force-deletes Pods bound to nonexistent nodes. Running it on the WDS would be wrong: it would wipe every stored node-pinned Pod, since the named node never exists there. The problem is that the graceful-deletion wait is not in kube-controller-manager and cannot be excluded the same way. The WDS keeps the waiter and rightly removes the cleaner. This gap needs to be closed one level up.

**Downstream, the whole system wedges on it.** The object never leaves the WDS, so the Binding keeps it, the ManifestWork is never deleted, and every spoke keeps running the Pod (verified: the spoke's AppliedManifestWork still lists the Pod long after the delete). The only way out is a manual `kubectl delete --force --grace-period=0` against the WDS.

### Steps To Reproduce

Self-contained bundle (same layout as the previous issues):

`manual_tests/nodepin_pod_undeletable_repro/`

Test folder: [nodepin_pod_undeletable_repro](https://github.com/munachimso-victor/UrsaPublic/tree/main/manual_tests/nodepin_pod_undeletable_repro)

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** Phase A is the control — the identical pinned Pod created **directly on the edge** deletes in about a second (node and kubelet exist there). Phase B goes through the hub: the downsynced pinned Pod is delivered and Running on the named node; the delete on the WDS hangs to kubectl's timeout and the Pod sits in `Terminating` (deletion timestamp set, no finalizers) past two ~5-minute agent resyncs, while the edge keeps running it and the ManifestWork stays green; a `--force --grace-period=0` delete on the WDS then clears hub, ManifestWork and edge within seconds. (Cluster names in this bundle are `repro-hub` / `repro-1/2/3` on port 9450, so it can run next to a default kubeflex install.)

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/nodepin_pod_undeletable_repro
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

#### Step 3 — Phase A: the control, directly on the edge (no KubeStellar)

```bash
kubectl --context repro-2 create ns ctl-nodepin
sed -e 's/name: pinned-pod/name: ctl-pinned-pod/' -e 's/namespace: nodepin-demo/namespace: ctl-nodepin/' \
    nodepin_seed.yaml | kubectl --context repro-2 apply -f -
sleep 8
kubectl --context repro-2 get pod ctl-pinned-pod -n ctl-nodepin -o wide

time kubectl --context repro-2 delete pod ctl-pinned-pod -n ctl-nodepin --timeout=60s
kubectl --context repro-2 delete ns ctl-nodepin --wait=false
```

The Pod runs on `repro-2-control-plane` and the delete completes in ~1 s.

#### Step 4 — Phase B1: downsync the pinned Pod

```bash
kubectl --context wds1 apply -f nodepin_seed.yaml
kubectl --context wds1 apply -f nodepin_policy.yaml
sleep 60

kubectl --context repro-2 get pod pinned-pod -n nodepin-demo -o wide
```

Delivered: `Running` on `repro-2-control-plane`. Pinning works through KubeStellar.

#### Step 5 — Phase B2: delete the Pod on the WDS (the bug)

```bash
time kubectl --context wds1 delete pod pinned-pod -n nodepin-demo --timeout=60s
kubectl --context wds1 get pod pinned-pod -n nodepin-demo \
  -o jsonpath='phase={.status.phase} deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}'; echo

sleep 720   # spans two ~5-min agent resyncs

kubectl --context wds1 get pod pinned-pod -n nodepin-demo
kubectl --context repro-2 get pod pinned-pod -n nodepin-demo
kubectl --context its1 get manifestwork -n repro-2 -o json | \
  python3 -c "import json,sys;[print(w['metadata']['name'],'deletionTimestamp=',w['metadata'].get('deletionTimestamp'),[(c['type'],c['status']) for c in w.get('status',{}).get('conditions',[])]) for w in json.load(sys.stdin)['items'] if 'nodepin' in str(w.get('spec'))]"
```

**Bug:** the delete hangs to kubectl's timeout ("timed out waiting for the condition"); the WDS Pod shows `Terminating` with a deletion timestamp and **no finalizers**, and is still `Terminating` after 720 s; the edge Pod is still `Running`; the ManifestWorks carry no deletion mark and report `Applied=True / Available=True`.

#### Step 6 — Phase B3: the only way out

```bash
time kubectl --context wds1 delete pod pinned-pod -n nodepin-demo --force --grace-period=0
sleep 30
kubectl --context wds1 get pod pinned-pod -n nodepin-demo
kubectl --context repro-2 get pod pinned-pod -n nodepin-demo
```

The force delete returns immediately; within seconds the ManifestWork is deleted and the edge Pod is removed. Everything downstream worked all along; only the WDS-side graceful deletion can never complete.

### Expected behavior

Deleting a downsynced node-pinned Pod on the WDS completes, the ManifestWork is removed, and the spokes stop running the Pod — without the user needing to know about `--force --grace-period=0`.

### Environment

- KubeStellar v0.29.0 (kubeflex-hosted WDS v1.29.9, ITS k3s, edges kind v1.37.0)
- Also observed systematically in our fleet testing (v4 and v5 runs): every deletion or delete-and-recreate of a node-pinned Pod through the WDS times out the same way.

`kubestellar-snapshot.tar.gz` attached after reproduction.
