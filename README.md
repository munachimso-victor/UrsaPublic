# UrsaPublic

Public home for **manual KubeStellar repro bundles** and related YAML developed alongside Ursa (a private multi-cluster BindingPolicy / workload testing harness).

This repo is **not** the Ursa engine. It holds self-contained artifacts you can share in bug reports, demos, or reviews without access to the private testing codebase.

## Layout

```
UrsaPublic/
└── manual_tests/
    ├── <topic>_repro/     # self-contained repro package (preferred)
    ├── *.yaml             # standalone seed / BindingPolicy snippets
    └── *.txt              # top-level repro notes (some cases)
```

Each `*_repro/` directory is meant to stand alone. Typical contents:

| File / dir | Purpose |
|------------|---------|
| `REPRO.txt` | Goal, expected failure, step-by-step commands |
| Seed / policy YAML | Workload + BindingPolicy to apply on WDS |
| Setup / Kind helpers | Optional cluster bootstrap for that case |
| `fix-klusterlet-rbac.yaml` | Extra edge RBAC when the case needs it |
| Sample logs | Captured failure output from a known run |

Paths in each `REPRO.txt` are relative to that folder. Browse `manual_tests/` for the current set of packages—new repros are added there over time.

## How to use a repro

1. Bring up a KubeStellar / KubeFlex-style environment (WDS + ITS + at least one edge), or follow the scripts inside the specific package.
2. Open that package’s `REPRO.txt` and follow it from a clean slate.
3. Compare your ManifestWork / edge object status to the expected failure described there (and to any sample log in the folder).

Exact contexts (`wds1`, `its1`, `edge-1`, …) and `KUBECONFIG` paths vary by install; adjust to your cluster names.

## Relationship to Ursa

Ursa’s automated suites found or sharpened many of these cases. This repo keeps the **human-reproducible** slice public: manifests, policies, and writeups suitable for upstream KubeStellar issues or external collaborators.

## Contributing

- Prefer one directory per bug, with a clear `REPRO.txt` and minimal YAML.
- Keep sample logs trimmed to the failing ManifestWork / object status when possible.
- Do not commit kubeconfigs, credentials, or live cluster secrets.
