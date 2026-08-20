# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`[Bug]: Host-type WDS is not an isolated authoring space — hub-local state (e.g. nodeName) downsyncs to spokes`

Paste below the line into a new issue. Attach `sample_log.txt` and
`kubestellar-snapshot.tar.gz` (optional but helpful).

---

### Describe the bug

Hello KubeStellar Maintainers,

I came across a behavior with setting WDS type as host that I think should be further looked at.

When **WDS type=host** (`WDSes=[{"name":"wds1","type":"host"}]`), `wds1` shares the **hosting Kind cluster apiserver**. Workloads authored there are subject to **hub-local controllers** (scheduler, Service allocator, etc.), and as a result transport wraps **live WDS state** into ManifestWork and downsyncs it to edge clusters.

This goes against the idea of keeping the WDS as a dumbed-down / isolated authoring space to avoid interference from hub controllers. As a result, **cluster-specific data from the hub hosting cluster can trickle to edges** even when the user never put those values in the seed YAML.

We believe **WDS should be restricted to an isolated authoring space** (as with kubeflex-type WDS). Without isolation, hub-local bindings and allocations are treated as portable desired state for edge clusters — which is incorrect for multi-cluster delivery.

### Details

A good example of where this goes wrong is **`spec.nodeName`**.

The hub scheduler binds a Pod to the hosting Kind node; the wrap includes that node name; the edge has no such Node.

1. User applies `pod_seed.yaml` on `wds1` (**no** `spec.nodeName` in the seed).
2. Hub scheduler binds the Pod to the hosting Kind node (e.g. `kubeflex-control-plane`).
3. BindingPolicy downsyncs; ManifestWork wrap includes that **hub** `spec.nodeName`.
4. Edge applies the Pod with a node name that **does not exist** on the spoke.
5. Edge orphan-pod GC deletes it; work-agent recreates → create/delete ping-pong.

The resulting edge symptom is similar to [#3964](https://github.com/kubestellar/kubestellar/issues/3964), but this is a more realistic case: the user did **not** set a wrong `nodeName` — the edge still received one because host-type WDS + wrap of live hub state injected it.

The same isolation gap can affect other hub-provisioned cluster-local fields (e.g. Service IPs / CIDR allocations from the hub allocator when those must be provisioned independently on each spoke).

**Manual repro results** (`sample_log.txt` in bundle):

| Where | Observation |
|-------|-------------|
| WDS (host) | Pod `Running`, `nodeName=kubeflex-control-plane` (scheduler-stamped; not in seed) |
| ManifestWork wrap | `spec.nodeName: kubeflex-control-plane` |
| edge-1 watch | Pod flaps `Pending` → `Failed`, always with `NODE=kubeflex-control-plane` |
| Nodes | wds1 has `kubeflex-control-plane`; edge-1 has only `edge-1-control-plane` |

### Steps To Reproduce

Self-contained bundle:

`manual_tests/host_wds_pod_nodename_pingpong_repro/`

Full copy/paste steps: `REPRO.txt` in that folder.

**Requires host-type WDS** — do not use a kubeflex-type WDS setup (that hides this path).

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/host_wds_pod_nodename_pingpong_repro
chmod +x install_requirements.sh setup_kubestellar_wds1host.sh \
  create-kind-cluster-with-SSL-passthrough.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar setup (WDS type=host, single edge-1)

```bash
export KUBECONFIG=~/.kube/kubeflex
./setup_kubestellar_wds1host.sh
kubectl config get-contexts
kubectl --context wds1 get nodes -o wide
kubectl --context edge-1 apply -f fix-klusterlet-rbac.yaml
```

Expect: `wds1` aliases `kind-kubeflex`; one spoke `edge-1`.

#### Step 3 — Apply Pod (no nodeName in seed)

```bash
kubectl --context wds1 apply -f pod_seed.yaml
kubectl --context wds1 apply -f pod_policy.yaml
sleep 15

HUB_NODE=$(kubectl --context wds1 get nodes -o jsonpath='{.items[0].metadata.name}')
echo "hub node=${HUB_NODE}"

kubectl --context wds1 -n ursa-namespace-template get pod ursa-host-wds-pod \
  -o jsonpath='wds phase={.status.phase} nodeName={.spec.nodeName}{"\n"}'
```

Expect: WDS Pod has `nodeName` = hub Kind node (stamped by scheduler, not in seed).

#### Step 4 — ManifestWork carries hub nodeName

```bash
kubectl --context its1 -n edge-1 get manifestworks
kubectl --context its1 -n edge-1 get manifestworks -o yaml | grep -B5 -A30 'kind: Pod'
```

Expect: wrap includes `spec.nodeName: kubeflex-control-plane` (or your hub node name).

#### Step 5 — Edge ping-pong (`kubectl -w`)

```bash
kubectl --context edge-1 -n ursa-namespace-template get pods \
  -l ursa-workload=host-wds-nodename -o wide -w
```

Leave running until you see Pending → Failed cycles (Ctrl-C to stop).

Expect: `NODE` column stays `kubeflex-control-plane` on every recreate.

#### Step 6 — Edge nodes vs hub node (why it fails)

```bash
kubectl --context wds1 get nodes -o wide
kubectl --context edge-1 get nodes -o wide
kubectl --context edge-1 -n ursa-namespace-template get pod ursa-host-wds-pod -o wide
```

Expect:

- **wds1:** node `kubeflex-control-plane` exists (Pod was scheduled there on the hub).
- **edge-1:** only `edge-1-control-plane` — **no** `kubeflex-control-plane`.
- **Edge Pod:** `NODE` / `spec.nodeName` = `kubeflex-control-plane` — a hub node name on a cluster that does not have that node.

### Expected behavior

**WDS should be an isolated authoring space** for objects that will be downsynced to spokes. Hub-local cluster state — node bindings, Service CIDR allocations, and similar fields provisioned on the hosting cluster — **must not** be wrapped and delivered as spoke desired state.

For host-type WDS specifically, either:

- document that it is unsuitable for schedulable / cluster-local workloads destined for spokes, **or**
- ensure wrap/downsync strips or ignores hub-local fields so edges never receive hosting-cluster node names, IP ranges, etc.

### Screenshots / logs

Attach:

- `manual_tests/host_wds_pod_nodename_pingpong_repro/sample_log.txt`
- `kubestellar-snapshot.tar.gz` (optional)

### Environment

- KubeStellar version: **0.29.0** (core-chart helm install, `WDSes=[{"name":"wds1","type":"host"}]`)
- Kubernetes version: **1.36.1** (kindest/node:v1.36.1)
- Host OS: Linux (Kind)

### Additional context

Manual repro bundle: `manual_tests/host_wds_pod_nodename_pingpong_repro/`

Related:

- [#3964](https://github.com/kubestellar/kubestellar/issues/3964) — same edge recreate loop when an invalid `nodeName` reaches the spoke (hardcoded in seed). This issue is the host-WDS path that injects hub `nodeName` without the user setting it.
- Service clusterIP / nodePort on kubeflex WDS (related theme of cluster-local fields): `manual_tests/service_clusterip_nodeport_repro/`
