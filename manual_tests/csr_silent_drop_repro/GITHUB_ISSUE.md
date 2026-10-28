# GitHub-ready text for kubernetes/kubernetes (bug report)

Status: DRAFT 2026-10-28 — user will review before submission.
Open points: (1) name the tool/paper or stay anonymous (same choice as the EndpointSlice issue);
(2) DONE 2026-10-28 — v5 fleet edges and oracles are v1.29.8 (each shard's config.json; hub v1.29.9); (3) DONE — the issue links REPRO.txt and the two manual logs in UrsaPublic
(manual_tests/csr_silent_drop_repro/, main); the links resolve only once the folder is copied there; (4) sig label: the
template asks for none, but /sig auth is the CSR owner (add as a comment after filing if wanted).
Re-verified 2026-10-28: master strategy.go still resets the spec; v1.37.2 and v1.38.0-alpha.3 both drop.

**Suggested title:**

`CertificateSigningRequest spec updates report success but are silently discarded; the immutability check from #142354 cannot fire`

---

### What happened?

The spec of a CertificateSigningRequest (CSR) is immutable after creation. But instead of rejecting a change to it — as the [API conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md#considerations-for-put-operations) require ("Be careful to detect and report legitimate errors where the 'new' value is specified but is different from the 'old' value") and as other kinds with immutable fields do — kube-apiserver discards the change silently and reports success:

- `kubectl patch` says `patched (no change)`
- `kubectl apply` says `configured`
- `kubectl replace` says `replaced`

and the stored value never changes. The client gets no error and no warning, so it has no way to learn that its change was discarded. For contrast, changing the immutable `spec.controller` of an IngressClass is rejected with `field is immutable` (shown below).

Where: `csrStrategy.PrepareForUpdate` (`pkg/registry/certificates/certificates/strategy.go`) does `newCSR.Spec = oldCSR.Spec`.

A fix was merged for 1.38 (#142354: an immutability check on `spec`; CSR is also listed in the KEP-5073 immutable-fields migration, #136785), but it cannot fire: kube-apiserver runs `PrepareForUpdate` BEFORE validation (`staging/src/k8s.io/apiserver/pkg/registry/rest/update.go`, `BeforeUpdate`), so the check compares the already-reset spec with itself. The PR's tests never go through `PrepareForUpdate`: the unit test calls `ValidateCertificateSigningRequestUpdate` directly, and the declarative-validation test calls `rest.ValidateUpdate` rather than `rest.BeforeUpdate`, which is why they pass. The 1.38 pre-releases (verified on v1.38.0-alpha.3) behave exactly like 1.37.

### What did you expect to happen?

An update that changes an immutable CSR `spec` field should be rejected with an error (as `IngressClass`, `PersistentVolume` and others do), not reported as a success.

### How can we reproduce it (as minimally and precisely as possible)?

Two containers, no cluster needed: etcd + kube-apiserver at the version under test. Setting them up — step 1 (key material and kubeconfig) and step 2 (starting etcd and kube-apiserver) — is in [REPRO.txt](https://github.com/munachimso-victor/UrsaPublic/blob/main/manual_tests/csr_silent_drop_repro/REPRO.txt). Then create a CSR with `spec.expirationSeconds: 86400` and try to change it to 3600 three ways:

```sh
openssl req -new -newkey rsa:2048 -nodes -keyout req.key -subj "/CN=csr-drop-test" -out req.csr
cat > csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: csr-silent-drop-test
spec:
  request: $(base64 -w0 req.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF
kubectl apply -f csr.yaml
# certificatesigningrequest.certificates.k8s.io/csr-silent-drop-test created
kubectl patch csr csr-silent-drop-test --type json \
  -p '[{"op":"replace","path":"/spec/expirationSeconds","value":3600}]'
# certificatesigningrequest.certificates.k8s.io/csr-silent-drop-test patched (no change)
sed 's/expirationSeconds: 86400/expirationSeconds: 3600/' csr.yaml | kubectl apply -f -
# certificatesigningrequest.certificates.k8s.io/csr-silent-drop-test configured
kubectl get csr csr-silent-drop-test -o yaml | sed 's/expirationSeconds: 86400/expirationSeconds: 3600/' | kubectl replace -f -
# certificatesigningrequest.certificates.k8s.io/csr-silent-drop-test replaced
kubectl get csr csr-silent-drop-test -o jsonpath='{.spec.expirationSeconds}{"\n"}'
# 86400   <- after every one of the three
```

For contrast, the same kind of change on an IngressClass is rejected:

```sh
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: contrast
spec:
  controller: example.com/a
EOF
# ingressclass.networking.k8s.io/contrast created
kubectl patch ingressclass contrast --type merge -p '{"spec":{"controller":"example.com/b"}}'
# The IngressClass "contrast" is invalid: spec.controller: Invalid value: "example.com/b": field is immutable
```

Terminal logs of the full step-by-step run: [v1.37.2](https://github.com/munachimso-victor/UrsaPublic/blob/main/manual_tests/csr_silent_drop_repro/sample_log_v1.37.2.txt) and [v1.38.0-alpha.3](https://github.com/munachimso-victor/UrsaPublic/blob/main/manual_tests/csr_silent_drop_repro/sample_log_v1.38.0-alpha.3.txt).

### Anything else we need to know?

We found this while researching a testing tool for multi-cluster orchestrators (systems that manage many Kubernetes clusters). The tool makes the same change directly on a plain single cluster and uses that cluster as the reference for what the multi-cluster system should end up with. Because the tool trusts the single cluster to be accurate, this went unnoticed until we manually checked whether the updates had actually taken place.

We first saw it in our test fleet (v1.29.8) and in a manual reproduction on v1.37.2. While investigating, we found the fix merged in #142354, but v1.38.0-alpha.3, which includes it, still discards the change. Our tests run on kind, which does not publish node images for Kubernetes pre-releases, so we tested v1.38.0-alpha.3 against the upstream kube-apiserver image directly.

Because our testing tool runs on kind, which publishes node images only for stable releases (no alphas or betas), we can only use a fix once it ships in a release. Could the real fix be backported to 1.37 (for example 1.37.3), or land before the 1.38 code freeze (16 November) so that it is in 1.38.0 (due 16 December)? Otherwise 1.38 would ship with the current check, which cannot fire.

### Kubernetes version

<details>

```console
$ kubectl version
Server Version: v1.37.2          # bug present
Server Version: v1.38.0-alpha.3  # bug present (carries #142354)
```


</details>

### Cloud provider

<details>
None (standalone kube-apiserver container).
</details>

### OS version

<details>
Not relevant (reproduced in the upstream registry.k8s.io/kube-apiserver images).
</details>

### Install tools

<details>
docker run of registry.k8s.io/etcd:3.6.4-0 and registry.k8s.io/kube-apiserver:<version>.
</details>

### Container runtime (CRI) and version (if applicable)

<details>
Not applicable.
</details>

### Related plugins (CNI, CSI, ...) and versions (if applicable)

<details>
None.
</details>
