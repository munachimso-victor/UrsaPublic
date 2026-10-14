# GitHub-ready text for kubestellar/kubestellar

**Suggested title:**

`[Bug]: Service transformation turns a valid hub object into one the edges refuse (externalTrafficPolicy stripped, healthCheckNodePort kept)`

Related but distinct from:
- https://github.com/kubestellar/kubestellar/issues/3978 (Service pins stripped — this one is a self-contradictory wrapped object that no cluster can apply)

Paste below the line into a new issue. After you reproduce, attach
`kubestellar-snapshot.tar.gz` as in the previous issues.

---

### Describe the bug

Hi KubeStellar Maintainers,

We came across another issue with how KubeStellar transforms a Service before sending it out to the edges.

For a Service, when we set externalTrafficPolicy to `Local` and the Service type to `LoadBalancer`, the apiserver auto-allocates `spec.healthCheckNodePort` (a nodePort that kube-proxy serves health checks on, so the cloud LB can tell which nodes actually have local endpoints).

Now when KubeStellar sends this Service to the edges, it strips `externalTrafficPolicy` (per its built-in Service transform), however it leaves the `healthCheckNodePort` field in and sends it to the edge.

Upon arrival, the edge apiserver validates the object and finds it illegal, as a `healthCheckNodePort` may only exist if type is `LoadBalancer` and `externalTrafficPolicy` is `Local`. The policy is missing, hence the object is rejected by Kubernetes at the edge:

```
Failed to apply manifest: Service "..." is invalid: spec.healthCheckNodePort:
Invalid value: 30442: may only be set when `type` is 'LoadBalancer' and
`externalTrafficPolicy` is 'Local'
```

KubeStellar takes a valid object at the hub and sends a broken object to the edge. The work agent retries the same payload forever, so the ManifestWork sits at `Applied=False` permanently while the WDS object, the BindingPolicy and the Binding all look healthy. The edges end up with no Service at all.

### Details

The built-in Service transform is documented in [transforming-desired-state](https://kubestellar.io/docs/user-guide/usage/kubestellar-api/transforming-desired-state):

> remove the following fields from `spec`: `ipFamilies`, `externalTrafficPolicy`, `internalTrafficPolicy`, `ipFamilyPolicy`, `sessionAffinity`. Also remove the `nodePort` field from every port unless the annotation `control.kubestellar.io/preserve=nodeport` is present.

`healthCheckNodePort` is not on the removal list, so by the transform's own specification it strips `externalTrafficPolicy` while forwarding the field that is only legal in its presence. Kubernetes enforces this dependency in both directions:

- `type: LoadBalancer` + `externalTrafficPolicy: Local` → the apiserver allocates `healthCheckNodePort` if not set;
- `healthCheckNodePort` present → validation requires `type: LoadBalancer` AND `externalTrafficPolicy: Local`.

So any Service in the LoadBalancer+Local combination produces a self-contradictory wrapped object that **no cluster can apply**. On the hub the trio is valid; after the transform it is not.

Note that `healthCheckNodePort` has the same dual nature as `nodePort` and `clusterIP`: a user can also pin it explicitly in the manifest. So this is not only hub-allocated data leaking through. A user who deliberately sets `healthCheckNodePort` on the WDS gets every edge refused as well, because the transform deletes the `externalTrafficPolicy` that makes their value legal.

Yet unlike `nodePort` (which has `control.kubestellar.io/preserve=nodeport`), there is no preserve or strip control for this field. It is always forwarded blindly next to the removal that invalidates it. Ideally, if a user doesn't specify the healthCheckNodePort, the hub generated one shouldn't be sent to the edges. But that is a separate issue from the one reported here.

The core problem is that the hard-coded removal list does not account for field dependencies, so any field whose legality depends on a stripped field will break the same way.

The idea for stripping IPs and ports is valid, but it takes more nuance than just a fixed list of fields to be stripped.

### Steps To Reproduce

Self-contained bundle (same layout as #3959 / the claimRef issue):

`manual_tests/service_healthchecknodeport_repro/`

Test folder: [service_healthchecknodeport_repro](https://github.com/munachimso-victor/UrsaPublic/tree/main/manual_tests/service_healthchecknodeport_repro)

Full copy/paste steps: `REPRO.txt` in that folder.

**Repro shape:** use the **same WEC (`edge-1`)** and the **same `service_seed.yaml`** twice — first applied **directly** on the edge (control: admitted cleanly, `healthCheckNodePort` allocated locally), then after cleanup applied **via WDS** downsync (bug: every edge refuses it).

The seed is from our automated test generation; the only change from the generated original is the testcase's legal `spec.type` value (`NodePort` → `LoadBalancer`) baked into the yaml.

#### Step 1 — Host prereqs

```bash
cd /path/to/manual_tests/service_healthchecknodeport_repro
chmod +x install_requirements.sh
./install_requirements.sh
```

#### Step 2 — KubeStellar cluster setup

```bash
cd /path/to/manual_tests/service_healthchecknodeport_repro
export KUBECONFIG=~/.kube/kubeflex
./setup_kubestellar.sh

kubectl --context edge-1 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-2 apply -f fix-klusterlet-rbac.yaml
kubectl --context edge-3 apply -f fix-klusterlet-rbac.yaml
```

#### Step 3 — Phase A: apply seed directly on `edge-1` (control — admitted cleanly)

```bash
export KUBECONFIG=~/.kube/kubeflex
cd /path/to/manual_tests/service_healthchecknodeport_repro

kubectl --context edge-1 apply -f service_seed.yaml
sleep 10

kubectl --context edge-1 get svc -n ursa-namespace-template ursa-nodeport-localized-template -o wide
kubectl --context edge-1 get svc -n ursa-namespace-template ursa-nodeport-localized-template \
  -o jsonpath='type={.spec.type} externalTrafficPolicy={.spec.externalTrafficPolicy} healthCheckNodePort={.spec.healthCheckNodePort}{"\n"}'
```

**Phase A success (control):**

- Service exists; `type=LoadBalancer externalTrafficPolicy=Local healthCheckNodePort=<allocated>`
- (`EXTERNAL-IP <pending>` on kind is expected and irrelevant to the bug)

#### Step 4 — Clean up `edge-1` before hub push

```bash
export KUBECONFIG=~/.kube/kubeflex

kubectl --context edge-1 delete -f service_seed.yaml --ignore-not-found --wait=false
sleep 30

kubectl --context edge-1 get svc -n ursa-namespace-template ursa-nodeport-localized-template 2>&1
kubectl --context edge-1 get ns ursa-namespace-template 2>&1
# both NotFound before continuing
```

#### Step 5 — Phase B: same yaml via WDS + BindingPolicy (bug)

```bash
export KUBECONFIG=~/.kube/kubeflex
cd /path/to/manual_tests/service_healthchecknodeport_repro

kubectl --context wds1 apply -f service_seed.yaml
kubectl --context wds1 apply -f service_policy.yaml
sleep 60
```

#### Step 6 — Verify Phase B

```bash
export KUBECONFIG=~/.kube/kubeflex

# WDS: the trio is valid on the hub (policy present, port allocated)
kubectl --context wds1 get svc -n ursa-namespace-template ursa-nodeport-localized-template \
  -o jsonpath='type={.spec.type} externalTrafficPolicy={.spec.externalTrafficPolicy} healthCheckNodePort={.spec.healthCheckNodePort}{"\n"}'

# ManifestWork payload: healthCheckNodePort kept, externalTrafficPolicy GONE
kubectl --context its1 -n edge-1 get manifestworks -o yaml | \
  grep -B6 -A10 'healthCheckNodePort'

# ManifestWork status: Applied=False with the validation refusal
kubectl --context its1 -n edge-1 get manifestworks -o yaml | \
  grep -B3 -A3 'Failed to apply manifest'

# edge-1: namespace delivered, Service refused
kubectl --context edge-1 get ns ursa-namespace-template
kubectl --context edge-1 get svc -n ursa-namespace-template ursa-nodeport-localized-template 2>&1
```

**Phase B success (bug reproduced):**

- WDS Service: `type=LoadBalancer externalTrafficPolicy=Local healthCheckNodePort=3xxxx` (valid)
- Wrapped manifest: `healthCheckNodePort` present, `externalTrafficPolicy` **absent**
- ManifestWork `Applied=False`:
  `Service "ursa-nodeport-localized-template" is invalid: spec.healthCheckNodePort: Invalid value: 3xxxx: may only be set when 'type' is 'LoadBalancer' and 'externalTrafficPolicy' is 'Local'`
- `edge-1`: namespace exists, Service **NotFound** — permanently (the agent retries the same payload)
- Same yaml that was admitted cleanly in Phase A

Snapshot after Step 6:

```bash
export KUBECONFIG=~/.kube/kubeflex
bash <(curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/refs/heads/main/scripts/kubestellar-snapshot.sh) \
  -K ~/.kube/kubeflex -V -Y -L
```

### Expected Behavior

The transform should not produce an object that is illegal by construction:

- strip `healthCheckNodePort` together with `externalTrafficPolicy` (it is the dependent, auto-allocated field), **or**
- do not strip `externalTrafficPolicy` (it is user intent, never cluster-generated).

In general, the removal list must respect Kubernetes field dependencies.

### Additional Context

Observed on KubeStellar v0.29.0 (hub and edges on Kubernetes v1.36.1), but nothing here is version-specific — the allocation and validation rules are long-standing Kubernetes behavior.

In our automated runs this hit every mode combination of the `nodeport-localized` seed whose testcase legally flipped `spec.type` to `LoadBalancer` (6/6 runs): edges ended with no Service while hub and BindingPolicy reported healthy.
