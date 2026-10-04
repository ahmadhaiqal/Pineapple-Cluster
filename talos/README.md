# Talos node configuration (talhelper)

A **git-native replacement for Sidero Omni's** node-configuration role, built
with [talhelper](https://github.com/budimanjojo/talhelper).

> **STATUS: authoritative for the rebuilt cluster (decided 2026-10-04).**
> The Omni cluster is not migrated — it is **wiped and rebuilt** with fresh PKI
> from `talhelper gensecret` (`talsecret.sops.yaml`), and data is restored from
> backups. Sections below the runbook are kept as the 2026-09-18 history of how
> the config was reconstructed; anything there about "the PKI blocker" or a
> live cutover no longer applies.

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
talsecret.sops.yaml       # cluster PKI, SOPS/age-encrypted (whole file)
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

## Rebuild runbook (Omni → standalone Talos)

Target: **Talos v1.14.2 / Kubernetes v1.36.5** (1.37 waits for Cilium 1.20 to
support it — see `talconfig.yaml`), installer schematic
`613e1592…` (`iscsi-tools` + `util-linux-tools`, **no SideroLink kernel args**).
The `v2-data-engine` patch is gone (it reserved 2 GiB of hugepages per node for
a Longhorn engine that was never enabled).

### What is lost, what comes back

| Data | Source | Notes |
|---|---|---|
| 4 CNPG databases | R2 `pineapple-pg-backups`, newest **2026-09-29** | nightly jobs stalled after that |
| App PVCs (17 archives) | ORICO `cluster-backups/20260919T031523Z/pvc/` | anything changed after **2026-09-19** is lost |
| Immich originals | ORICO itself (`/var/mnt/immich/upload`) | untouched — the disk is never formatted |
| `media-pvc` (movies/TV/music) | **nothing** | deliberately not backed up; re-download via Sonarr/Radarr/spotdl |
| Raw Longhorn volumes | **nothing** | urial-lab's NVMe is wiped |

### 0. Before touching either node

- [ ] urial-lab survives a sustained-load soak with the ORICO **unplugged**
      (the 2026-10-02 power-offs were power delivery, not Talos — a reinstall
      does not fix them).
- [ ] Router: DHCP reservations `ac:e2:d3:0b:32:34 → .113` (hippo-lab),
      `20:24:05:26:00:16 → .114` (urial-lab). The apiserver endpoint is `.113`.
- [ ] `~/Archive/age.agekey` copied somewhere off this workstation. Without it
      `talsecret.sops.yaml` and every `secrets.yaml` are unreadable.
- [ ] Download the latest R2 dumps locally as a second copy:
      `rclone copy r2:pineapple-pg-backups ./backup-staging/r2-final`
- [ ] Decide remote access (Omni provided it). LAN-only is the default; for
      remote `kubectl`/`talosctl` add `siderolabs/tailscale` to both schematics
      and re-render before installing.

### 1. Install media

```sh
# ISO for the same schematic as the installer, version-matched:
curl -LO https://factory.talos.dev/image/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245/v1.14.2/metal-amd64.iso
```

### 2. Render configs

```sh
export SOPS_AGE_KEY_FILE=~/Archive/age.agekey
cd talos && talhelper genconfig          # -> ./clusterconfig (gitignored)
talosctl validate --mode metal --strict -c clusterconfig/Talos-Pineapple-hippo-lab.yaml
talosctl validate --mode metal --strict -c clusterconfig/Talos-Pineapple-urial-lab.yaml
```

### 3. Wipe and install

1. **Unplug the ORICO from urial-lab.** `installDisk` is pinned to
   `/dev/nvme0n1`, but the only real guarantee is the cable.
2. Boot each node from the ISO → maintenance mode. If a node still has an old
   Omni-era install, choose the ISO's wipe/reset option or the installer
   will reuse the existing STATE.
3. Apply config (maintenance mode accepts `--insecure` only):
   ```sh
   talosctl apply-config --insecure -n 192.168.100.113 -f clusterconfig/Talos-Pineapple-hippo-lab.yaml
   talosctl apply-config --insecure -n 192.168.100.114 -f clusterconfig/Talos-Pineapple-urial-lab.yaml
   ```
4. Bootstrap etcd **once**, on hippo-lab only, then fetch credentials:
   ```sh
   export TALOSCONFIG=$PWD/clusterconfig/talosconfig
   talosctl -n 192.168.100.113 bootstrap
   talosctl -n 192.168.100.113 kubeconfig ~/.kube/config --force
   talosctl -n 192.168.100.113 health --wait-timeout 15m
   ```
   Nodes stay `NotReady` until Cilium lands in step 4 — expected (no CNI).
5. **Replug the ORICO**, then confirm the mount and pin it properly:
   ```sh
   talosctl -n 192.168.100.114 get discoveredvolumes -o yaml | grep -B5 -A15 xfs
   talosctl -n 192.168.100.114 get volumestatus immich
   ```
   Replace the `volume.name == "xfs" && disk.transport == "usb"` selector in
   `patches/urial-lab/immich-usb-disk.yaml` with the real UUID, re-render,
   `talosctl apply-config` (no `--insecure` now).

### 4. Cilium, then Flux

Chicken-and-egg: with `cni: none` no pod gets a network, so the Flux
controllers themselves cannot start until Cilium runs. Install Cilium once by
hand with the **same chart version and values** Flux uses; helm-controller then
adopts the release (same `releaseName: cilium`) instead of creating a second.

```sh
helm repo add cilium https://helm.cilium.io && helm repo update
helm install cilium cilium/cilium -n kube-system \
  --version "$(yq '.spec.chart.spec.version' ../infrastructure/controllers/base/cilium/release.yaml)" \
  -f ../infrastructure/controllers/base/cilium/values.yaml
kubectl get nodes -w            # both nodes go Ready once cilium-agent is up
```

`values.yaml` already points Cilium at KubePrism (`localhost:7445`), which
Talos enables by default — required, since there is no kube-proxy.

```sh
kubectl create ns flux-system
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/Archive/age.agekey
flux bootstrap github --owner=ahmadhaiqal --repository=Pineapple-Cluster \
  --branch=main --path=cluster/staging --personal
```

Watch Cilium → Longhorn → CNPG → apps (`flux get kustomizations -A -w`).
Then **suspend `apps` and `infrastructure-controllers`** before restoring, so
apps aren't writing into volumes while their data is put back.

### 5. Restore

- **Databases:** `pg_restore` each R2 dump into its fresh CNPG cluster — run
  it from a pod in-cluster, not through `kubectl exec` streaming.
- **PVCs:** extract each `pvc/<ns>/<pvc>.tar.gz` from the ORICO into the
  matching new PVC (`tar xzf <file> -C <mount>`), via a pod that mounts both
  the ORICO (`local` PV, as in `scripts/pre-wipe-backup.sh`) and the target.
- Resume Flux, then check every app through Cloudflare and confirm the next
  nightly R2 upload actually lands (`rclone ls r2:pineapple-pg-backups/`).

### 6. Leave Omni

Only once `talosctl` and `kubectl` work without Omni: delete the cluster in
the Omni UI, close the account, delete `omni/`, `./kubeconfig` and the Omni
contexts in `~/.kube/config` / `~/.talos/config`.

### Talos 1.14 gotchas hit while rendering

- **talhelper v3.1.17 warns** `"v1.14.2" might not be compatible` — harmless;
  its version table predates 1.14.2. `validate` and `genconfig` succeed.
- **kube-proxy / CNI are separate documents** now. The old
  `cluster.proxy.disabled: true` patch makes genconfig fail with
  `can't be used with KubeProxyConfig document`. See
  `patches/controlplane/cilium-cni.yaml`; `KubeProxyConfig` is
  control-plane-only (on a worker, validate fails).
- **`$patch: delete` must be written `$$patch`** — talhelper runs patches
  through envsubst and otherwise errors `variable ${patch} not set`.
- **Workload isolation stays off.** Fresh `talosctl gen config` emits
  `SecurityProfileConfig { workloadIsolation: true }`; talhelper 3.1.17 can't
  even decode that document (`not registered`) and so never emits it, and an
  absent document means off. Enable deliberately once Longhorn attaches are
  proven — see the 1.14 notes below.
- **Hostnames are lowercase** (`hippo-lab`, `urial-lab`): they become the k8s
  node names that `apps/` nodeAffinity rules pin to.
- **The ORICO is an `ExistingVolumeConfig`**, not `machine.disks`: it only
  mounts, never partitions or formats.

## Version policy (2026-09-18 — superseded by the rebuild)


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
