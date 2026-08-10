Manual repro: Secret downsync failures (minimal BindingPolicy)
==============================================================

Self-contained bug submission bundles for secrets that fail to downsync when
bound with only namespace (+ optional companion objects) on KubeStellar.

All paths below are relative to:

  manual_tests/secret_downsync_repro/

Planned secret folders (one per failing type from Ursa isolated runs):
  dockerconfigjsonsecret/   — started (3 policy-shape variants)
  bootstraptokensecret/     — TODO
  serviceaccounttokensecret/ — TODO
  basicauthsecret/          — TODO
  dockercfgsecret/          — TODO
  iscsichapsecret/          — TODO
  (opaque / ssh / tls pass in isolation — no repro folder needed)

Prerequisites
-------------
  Same as manual_tests/pvc_null_storageclass_repro/:
    Docker, kubectl, helm, kind, kflex, clusteradm 0.10.1
    KUBECONFIG=~/.kube/kubeflex
    Contexts: wds1, its1, edge-1, edge-2

  Fresh cluster setup (optional):
    cd manual_tests/pvc_null_storageclass_repro
    ./setup_kubestellar.sh
