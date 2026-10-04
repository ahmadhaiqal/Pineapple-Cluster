# Omni Node Configuration

Talos **machine-config** patches and **system-extension** selections for the
`Talos-Pineapple` cluster, managed by [Sidero Omni](https://omni.siderolabs.io/)
— **not** by FluxCD.

> ⚠️ FluxCD reconciles Kubernetes workloads (this repo's `apps/`,
> `infrastructure/`, etc.). It does **not** manage Talos OS / node
> configuration. Node-level config (kubelet args, mounts, NTP, hostnames) lives
> in Omni. The files here are a **version-controlled reference** of the patches
> applied out-of-band via `omnictl`; Omni remains the source of truth.

## Applying

```sh
# Requires an authenticated omnictl (browser SSO against the Omni instance).
omnictl apply -f omni/config-patches/<patch>.yaml           # create/update
omnictl apply -f omni/config-patches/<patch>.yaml --dry-run # preview
omnictl get configpatch                                     # list live patches
omnictl get extensionsconfiguration                         # list live extensions
```

> ⚠️ **Keep omnictl current.** A stale client fails with
> `client API version mismatch: backend API version 3, client API version 2`
> and cannot read *or* write anything — as of 2026-09-18 the omnictl in `$PATH`
> (`/home/linuxbrew/.linuxbrew/bin/omnictl`) was 1.8.2 against a 1.12.1 backend.
> `talosctl` still worked. **Resolved 2026-09-18** by fetching the matching
> binary directly — the Homebrew tap clone fails in this environment:
>
> ```sh
> curl -sSL -o omnictl \
>   https://github.com/siderolabs/omni/releases/download/v1.12.1/omnictl-linux-amd64
> chmod +x omnictl && ./omnictl get configpatch      # works
> ```
>
> Note also that Omni hands out an **operator-scoped** key: `talosctl get
> machineconfig` returns `PermissionDenied`, so the full machine config cannot
> be dumped from the CLI. Derived resources (`kubeletconfig`, `extensions`) are
> readable and are what the files here were verified against. Omni's own
> resource API will not serve cluster secrets to any role — see
> [`talos/README.md`](../talos/README.md), "The blocker: cluster PKI".

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
| `config-patches/500-longhorn-kubelet-mount.yaml` | cluster | Bind-mounts `/var/lib/longhorn` into the kubelet with `rshared` propagation so the Longhorn CSI driver can stage volumes. **Reference only** — already live, real patch ID unknown; reconcile before applying. |

## Extensions

| File | Scope | What |
|---|---|---|
| `extensions/longhorn-iscsi.yaml` | cluster | `iscsi-tools` (hard requirement for the Longhorn v1 data engine) + `util-linux-tools` (`fstrim`). **Reference only** — already live via schematic `6dd31f01…`; diff before applying. |

## Live patch inventory (verified 2026-09-18)

`omnictl get configpatch` against the upgraded client returns **11 user patches
plus 2 Omni-owned system patches**. The full content of every one is now
recorded in git under [`talos/patches/`](../talos/patches/) — written in
talhelper layout rather than as Omni `ConfigPatch` wrappers, because that is the
form needed to leave Omni. Nothing is unrecorded any more.

| Omni patch ID | Scope | Recorded as |
|---|---|---|
| `500-e0548e09-…` "cilium patch" | cluster | `talos/patches/global/cilium-cni.yaml` + `cniConfig` in talconfig |
| `500-kubelet-image-gc` | cluster | `talos/patches/global/kubelet-image-gc.yaml`, `config-patches/500-kubelet-image-gc.yaml` |
| `500-3c1648d3-…` / `500-4dc7c471-…` NTP | per-machine ×2 | `talos/patches/global/ntp-servers.yaml` (identical, collapsed) |
| `500-f70d4167-…` / `500-36361ff9-…` Data Path Mounts | per-machine ×2 | `talos/patches/global/longhorn-kubelet-mount.yaml` |
| `500-64408c87-…` / `500-73dcf9a9-…` V2 Data Engine | per-machine ×2 | `talos/patches/global/v2-data-engine.yaml` |
| `500-61382547-…` / `500-1e1f97a2-…` hostnames | per-machine ×2 | `hostname:` field per node in `talos/talconfig.yaml` |
| `500-a29dd9bc-…` "enable control plane schedule" | hippo-lab | `talos/patches/controlplane/control-plane-taint.yaml` |
| `500-759dfc08-…` "Add 2TB memory" | urial-lab | `talos/patches/urial-lab/immich-usb-disk.yaml` |
| `900-cm-…-kubernetes-upgrade` ×2 | Omni-owned | not reproduced — `kubernetesVersion:` in talconfig |

### Gaps closed

- **`/var/mnt/immich` on urial-lab** — was the standing gap. Recovered verbatim
  from patch `500-759dfc08-c080-4d9d-b050-b84df3ab6ebb`; it carries a
  `machine.disks` entry (`/dev/disk/by-id/usb-Linux_File-Stor_Gadget_1234567890-0:0`
  → `/var/mnt/immich`) as well as the kubelet bind-mount.
- **The Longhorn kubelet mount's "unknown patch ID"** — it is two separate
  machine-scoped patches, `500-f70d4167-…` (urial-lab) and `500-36361ff9-…`
  (hippo-lab), not one cluster-wide patch. `config-patches/500-longhorn-kubelet-mount.yaml`
  is therefore still **reference only**: applying it would add a third,
  duplicate `extraMounts` entry.

### Newly discovered, previously undocumented

- **"V2 Data Engine"** (`500-64408c87-…`, `500-73dcf9a9-…`) reserves
  `vm.nr_hugepages: 1024` — **2 GiB of RAM per node** — and loads `nvme_tcp` /
  `vfio_pci`, for Longhorn's v2 SPDK data engine. That engine is **not enabled**
  in `infrastructure/controllers/base/longhorn/values.yaml`; every volume runs
  on v1. Both nodes have been paying for it since 2025-08-27.

## Leaving Omni

See [`talos/`](../talos/) for a verified talhelper reconstruction of this entire
directory's subject matter, what still blocks a cutover, and the hazards
involved. The mechanical difference between an Omni node and a standalone one
turns out to be three kernel args baked into the installer schematic.
