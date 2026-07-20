# Omni Config Patches

Talos **machine-config** patches for the `Talos-Pineapple` cluster, managed by
[Sidero Omni](https://omni.siderolabs.io/) — **not** by FluxCD.

> ⚠️ FluxCD reconciles Kubernetes workloads (this repo's `apps/`,
> `infrastructure/`, etc.). It does **not** manage Talos OS / node
> configuration. Node-level config (kubelet args, mounts, NTP, hostnames) lives
> in Omni. The files here are a **version-controlled reference** of the patches
> applied out-of-band via `omnictl`; Omni remains the source of truth.

## Applying

```sh
# Requires an authenticated omnictl (browser SSO against the Omni instance).
omnictl apply -f omni/config-patches/<patch>.yaml          # create/update
omnictl apply -f omni/config-patches/<patch>.yaml --dry-run # preview
omnictl get configpatch                                     # list live patches
```

Patch IDs are prefixed with a weight (`500-` = normal user weight). A patch is
bound by label: `omni.sidero.dev/cluster: <cluster>` (cluster-wide) or
`omni.sidero.dev/machine: <machine-id>` (single node).

Machine IDs:

| Machine ID | Node | Role |
|---|---|---|
| `03000200-0400-0500-0006-000700080009` | urial-lab | worker |
| `43126e8a-4c7b-95ef-a96c-8e0b615bcb3c` | hippo-lab | control-plane |

## Patches

| File | Scope | What |
|---|---|---|
| `config-patches/500-kubelet-image-gc.yaml` | cluster | Lowers kubelet image-GC thresholds (high 70 / low 45) so unused container images from Renovate tag churn are auto-pruned. Added 2026-07-20 after ~546 GiB of orphaned image layers filled urial-lab. |
