# Talos node configuration (talhelper)

A **git-native replacement for Sidero Omni's** node-configuration role, built
with [talhelper](https://github.com/budimanjojo/talhelper).

> **STATUS: reference only. Omni is still the source of truth.**
> Nothing in this directory has been applied to a node. `talconfig.yaml` is a
> faithful, verified reconstruction of live state — the thing that was missing
> when `omni/README.md` said "Omni remains the source of truth" and then listed
> config that only existed inside Omni's database.

## Why this exists

Omni does two jobs for this cluster:

1. **Node config** — kubelet args, mounts, extensions, sysctls. Stored in
   Omni's DB, editable only through its UI/API. `omni/` is a hand-maintained
   *copy* that had already drifted.
2. **Remote access** — SideroLink (WireGuard) plus the SSO'd
   `amdhql.kubernetes.na-west-1.omni.siderolabs.io` kubeconfig.

This directory replaces job 1. Job 2 needs its own answer (Tailscale via the
`siderolabs/tailscale` extension is the usual one) before Omni can be dropped.

## Layout

```
talconfig.yaml            # the whole cluster, one file
patches/global/           # applied to both nodes
patches/controlplane/     # hippo-lab only
patches/urial-lab/        # worker only
clusterconfig/            # rendered output — gitignored, contains secrets
talsecret.sops.yaml       # cluster PKI — DOES NOT EXIST YET, see "The blocker"
```

Every patch file names the Omni ConfigPatch ID it was recovered from, so the
two can be diffed until Omni is retired.

## How this was reconstructed (2026-09-18)

`talosctl get machineconfig` returns `PermissionDenied` — Omni issues an
operator-scoped key — so the config was rebuilt from derived resources plus
Omni's own patch list:

```sh
omnictl get configpatch -o yaml                   # all 11 user patches, verbatim
omnictl get extensionsconfiguration -o yaml       # per-machine extension sets
omnictl get clusters -o yaml                      # talos/k8s versions
omnictl cluster template export --cluster Talos-Pineapple
talosctl -n <node> get kubeletconfig -o yaml      # rendered kubelet config
talosctl -n <node> get links,addresses,disks,timeservers,resolvers
talosctl -n hippo-lab get staticpods kube-apiserver -o yaml   # subnets, SANs
```

> ⚠️ **The omnictl in `$PATH` is too old.** `/home/linuxbrew/.linuxbrew/bin/omnictl`
> is v1.8.2 (API v2) against a v1.12.1 (API v3) backend and fails with
> `client API version mismatch` on *every* call — this is what made the earlier
> pass give up and write "real patch ID unknown" in `omni/README.md`. Grab the
> matching binary and everything works:
>
> ```sh
> curl -sSL -o omnictl https://github.com/siderolabs/omni/releases/download/v1.12.1/omnictl-linux-amd64
> chmod +x omnictl
> ```

## Verification performed

Rendered with a throwaway secret bundle into a scratch directory (never the
repo) and diffed against the live nodes:

```sh
talhelper validate talconfig                      # ✅ passes
talhelper gensecret > /tmp/throwaway.yaml
talhelper genconfig -s /tmp/throwaway.yaml -o /tmp/clusterconfig
```

| Checked | Result |
|---|---|
| kubelet `extraMounts` on urial-lab | ✅ exact match, same order (`/var/mnt/immich`, then `/var/lib/longhorn`) |
| kubelet `extraConfig` image-GC 70/45 | ✅ both nodes |
| `machine.disks` for the Immich USB disk | ✅ matches the live `/dev/sda1 → /var/mnt/immich` xfs mount |
| NTP servers, sysctls, kernel modules | ✅ both nodes |
| `cni: none`, `proxy.disabled: true` | ✅ matches live (no CNI or kube-proxy bootstrap manifest exists) |
| pod/service subnets, dnsDomain | ✅ `10.244.0.0/16`, `10.96.0.0/12`, `cluster.local` |
| control-plane `register-with-taints` | ✅ rendered |
| **System extensions** | ✅ `iscsi-tools` + `util-linux-tools`, identical set |
| **Schematic ID** | ⚠️ `613e1592…` vs live `6dd31f01…` — **expected**, see below |

### The schematic delta is the migration, in one diff

Both schematics fetched from `https://factory.talos.dev/schematics/<id>`:

```diff
  customization:
-     extraKernelArgs:
-         - siderolink.api=https://amdhql.siderolink.omni.siderolabs.io?jointoken=<redacted>
-         - talos.events.sink=[fdae:41e4:649b:9303::1]:8090
-         - talos.logging.kernel=tcp://[fdae:41e4:649b:9303::1]:8092
      systemExtensions:
          officialExtensions:
              - siderolabs/iscsi-tools
              - siderolabs/util-linux-tools
```

Three kernel args, baked into the installer image at boot time, are the entire
mechanical difference between an Omni-managed node and a standalone one. That
is why leaving Omni means booting a different installer image, not just
applying a different config.

## Version policy

`talconfig.yaml` targets **Talos v1.13.10 / Kubernetes v1.36.4** — the newest
patches on the lines the cluster already runs. Live is still v1.13.3 / v1.36.1;
this is the only place the file deliberately leads reality rather than
describing it.

**Do the patch upgrade in Omni, before the cutover.** Omni drives the rolling
reboot and health checks. A first-ever manual `talosctl upgrade` against a
single-control-plane cluster is not a good first exercise.

```sh
# in the Omni UI: Clusters → Talos-Pineapple → Update Talos / Update Kubernetes
omnictl get talosversions       # what this Omni instance offers
omnictl get kubernetesversions
```

Each node reboots, so the API is unavailable for a few minutes — with one
control plane there is no rolling path even for a patch bump.

### Expect a harmless talhelper warning

`talhelper validate talconfig` prints:

```
WARNING: "v1.13.10" might not be compatible with this Talhelper version you're using
```

**Ignore it.** talhelper v3.1.17 was published 2026-08-26; Talos v1.13.10
shipped 2026-09-03, a week later, so it is simply missing from the binary's
baked-in version table. `validate` still exits 0, and the render is correct
(installer `…:v1.13.10`, kubelet `v1.36.4`). The config schema does not change
across patch releases — talhelper 3.1.17 is itself built against
`talos/pkg/machinery v1.14.0-alpha.2`, well ahead of what we target.

### Why not Talos 1.14 / Kubernetes 1.37

Both are available in Omni (Talos v1.14.1, k8s v1.37.0) and both are a
deliberate "not yet". The two are coupled: **Talos 1.13.x caps at Kubernetes
1.36.4**, so 1.37 forces a Talos minor jump too.

- Two full-downtime events stacked next to each other, on a cluster with no
  rolling path, makes failures impossible to attribute.
- Talos 1.14.0 shipped 2026-09-03 with one patch behind it. Longhorn replicas
  here are single-copy on one node — wrong cluster to be early on.
- If the PKI question forces a rebuild, 1.14.1 + 1.37.0 get installed fresh
  anyway, and the pre-upgrade was wasted disruption.

### Talos 1.14 notes, for when it is time

- **`sandboxd` workload isolation** puts CRI, the kubelet and all pods in their
  own PID/mount namespace. *Upgraded* clusters do not get the
  `SecurityProfileConfig` document and keep the old behavior; **freshly
  generated configs default to `workloadIsolation: true`** — which is what
  talhelper would emit on a rebuild. Longhorn uses its own CSI driver (not the
  deprecated in-tree iSCSI plugin), so it should be unaffected in principle, but
  the `/var/lib/longhorn` `rshared` bind-mount crossing a new mount namespace is
  worth proving before trusting. On a rebuild: start `false`, confirm volumes
  attach, enable deliberately.
- **Deprecated, not removed** (so nothing here breaks on upgrade):
  `.machine.sysctls` and `.machine.kernel` → `SysctlConfig` /
  `KernelModuleConfig` documents; `.machine.features.hostDNS` → `ResolverConfig`.
  `patches/global/v2-data-engine.yaml` uses the first two.
- **Secret bundle cluster-ID encoding changed** from `base64.URLEncoding` to
  `base64.StdEncoding` — relevant if a 1.13-era PKI is transplanted with 1.14
  tooling.
- **`machine.disks` survives** — the Immich USB patch is safe.
- **etcd metrics moved 2379 → 2383.** Harmless here; the kube-prometheus-stack
  in `monitoring/` does not scrape etcd.

## The blocker: cluster PKI

talhelper needs `talsecret.sops.yaml` — the cluster CA keys, etcd CA, service
account key, bootstrap token. These live in Omni, and the obvious ways in are
all closed:

```
$ omnictl get clustersecrets           # also clustermachineconfigs, clustermachinesecrets
PermissionDenied: no access is permitted

$ talosctl -n hippo-lab get machineconfig
PermissionDenied: not authorized        # Omni issues an os:operator talosconfig

$ talosctl -n hippo-lab read /system/state/config.yaml
NotFound                                # STATE partition isn't in apid's mount namespace
```

**This is not a role problem** — `omnictl user list` confirms
`amd.hql@gmail.com` is **Admin**, and that command is itself Admin-only. Omni
simply does not serve cluster secrets over its resource API, and the talosconfig
it hands out is operator-scoped by design. (Plain `talosctl read` *does* work
for ordinary paths like `/etc/hosts` — it's specifically the machine config and
the STATE partition that are out of reach.)

### The one door left: break-glass

`omnictl talosconfig --break-glass` is documented as "get operator talosconfig
that allows bypassing Omni (**if enabled for the account**)". That config talks
to the nodes directly rather than through the Omni proxy, at `os:admin`, which
is the level `talosctl get machineconfig -o yaml` requires. From that output the
whole `cluster.secrets` bundle can be lifted into `talsecret.sops.yaml` and the
existing PKI preserved.

**Not run here.** It issues a privileged credential that bypasses Omni's audit
proxy, so it is the user's call, not an incidental step. When you want it:

```sh
omnictl talosconfig --break-glass --merge=false /tmp/breakglass-talosconfig
TALOSCONFIG=/tmp/breakglass-talosconfig talosctl -n 192.168.100.113 get machineconfig -o yaml
```

Then encrypt immediately — that output is every credential in the cluster:

```sh
sops --encrypt --age age1av8wp2lg5m6anyd94jg9x67st3prnkfnacrtl25ptlzjmc06gqsq0w85c3 \
  talsecret.yaml > talos/talsecret.sops.yaml && rm talsecret.yaml
```

### If break-glass is disabled for the account

`talhelper gensecret` makes a *new* PKI, which makes a *new* cluster: new CA,
new etcd identity, every node rejoining from scratch, every workload redeployed
from this repo. That is a rebuild, not a migration — price it accordingly.

**Do not run `talhelper gensecret` into this directory** before that question is
settled. A stray secret file is exactly how someone ends up believing the
running cluster can be reached with the wrong CA.

## Cutover hazards (read before scheduling anything)

- **One control plane.** hippo-lab *is* etcd. There is no rolling path; the
  cluster is down for the duration.
- **Longhorn replicas live on urial-lab's EPHEMERAL partition** and are
  single-replica (hippo-lab is tainted, so anti-affinity can't place a second).
  Wiping urial-lab destroys every PVC in `apps/` and `databases/`. Back up
  first — Longhorn backup target, or CNPG `barman` dumps for the databases.
- **The Immich 2 TB USB disk is a separate device** and is not touched by a
  system-disk wipe, but `machine.disks` will not re-partition a disk that
  already has the mountpoint — verify, don't assume.
- **Service-account issuer changes.** Live, kube-apiserver runs with
  `--service-account-issuer=https://[fdae:41e4:649b:9303::1]:10000` (Omni's
  SideroLink address). Off Omni it becomes the LAN endpoint, invalidating
  in-flight service account tokens; every pod needs a restart.
- **Suspend Flux** (`flux suspend kustomization --all`) before the cutover so it
  doesn't fight a half-built cluster, and resume after.

## Observation worth acting on independently

`patches/global/v2-data-engine.yaml` reserves **1024 hugepages (2 GiB of RAM)
per node** plus loads `nvme_tcp`/`vfio_pci`, for Longhorn's v2 (SPDK) data
engine — which is **not enabled** in
`infrastructure/controllers/base/longhorn/values.yaml`. Both nodes are paying
for it. Dropping that patch is a free 2 GiB per node; it is kept here only to
match live state faithfully.

## Once this is authoritative

```sh
talhelper genconfig                                  # render to ./clusterconfig
talosctl apply-config -n 192.168.100.113 -f clusterconfig/Talos-Pineapple-Hippo-Lab.yaml
talhelper gencommand apply --extra-flags --dry-run   # print the commands first
```

`clusterconfig/` and any unencrypted `talsecret.yaml` are gitignored — the
rendered files contain the cluster CA in plaintext.
