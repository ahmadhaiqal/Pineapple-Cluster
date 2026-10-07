#!/usr/bin/env bash
#
# post-rebuild-restore.sh — puts data back into the REBUILT (non-Omni) cluster.
# The inverse of scripts/pre-wipe-backup.sh; run it at step 5 of the runbook
# in talos/README.md, after Flux has created every namespace, PVC and CNPG
# cluster from git.
#
# What it restores:
#   databases  - the 4 CNPG databases, from the newest nightly dump in R2
#                (default) or from the ORICO backup set (--db-source orico).
#                Each target database is DROPPED and recreated first.
#   PVCs       - every pvc/<ns>/<pvc>.tar.gz in the ORICO backup set, extracted
#                into the matching new PVC. Each target PVC is EMPTIED first:
#                the apps have usually started once and written fresh state.
#   media-pvc  - not restored (never backed up); its folder tree is recreated
#                as 911:911 2775 so Sonarr/Radarr imports work (see CLAUDE.md).
#
# Not touched: immich-library. It lives on the ORICO itself and is mounted, not
# restored. The restored immich database points at those same files.
#
# Same pattern as the backup: every byte moves in-cluster, inside pods on
# hippo-lab that reach the ORICO through a temporary `local` PV (baseline
# PodSecurity forbids hostPath). Only one-line results cross the API.
#
# Usage:
#   scripts/post-rebuild-restore.sh                     # everything
#   scripts/post-rebuild-restore.sh --dry-run           # show the plan only
#   scripts/post-rebuild-restore.sh --only suwayomi,homarr
#   scripts/post-rebuild-restore.sh --skip-db | --skip-pvc
#   scripts/post-rebuild-restore.sh --skip-absent       # ignore PVCs of apps
#                                     not deployed (phased start), instead of
#                                     aborting; each one skipped is printed
#   scripts/post-rebuild-restore.sh --only movietime --pvc sonarr-config-pvc,radarr-config-pvc
#                                     # only these PVCs; only the apps whose name
#                                     prefixes them are scaled down. Implies
#                                     --skip-db. For phasing apps into a
#                                     namespace whose other apps are already live
#   scripts/post-rebuild-restore.sh --db-source orico   # 09-19 dumps, not R2
#   scripts/post-rebuild-restore.sh --stamp 20260919T031523Z
#
set -euo pipefail

NODE="hippo-lab"
HOST_MOUNT="/var/mnt/immich"          # ORICO mountpoint on the node
BACKUP_SUBDIR="cluster-backups"
SRC_PVC="restore-orico"               # temp PVC giving a namespace ORICO access
HELPER_POD="post-rebuild-restore"
TAR_IMAGE="debian:bookworm-slim"      # GNU tar: --numeric-owner, unlike busybox
# pg_restore must be >= the pg_dump that wrote the archive. The nightly R2
# dumps are written by the backup CronJob's image, which Renovate bumps (it
# went 16 -> 18 on 2026-09-24, and a 16 pg_restore rejects those archives with
# "unsupported version (1.16) in file header"). So each restore uses whatever
# image that namespace's CronJob runs now; this is only the fallback.
PG_IMAGE_FALLBACK="ghcr.io/cloudnative-pg/postgresql:18"
RCLONE_IMAGE="rclone/rclone:latest"
R2_BUCKET="pineapple-pg-backups"
R2_ENDPOINT="https://a1fed5c5eaa4445fb566ae6bc7f8b079.r2.cloudflarestorage.com"
MEDIA_UID=911                         # movietime shared-storage owner, see CLAUDE.md

DB_SOURCE="r2"
STAMP=""
ONLY=""
PVC_ONLY=""
DO_DB=1
DO_PVC=1
DRY_RUN=0
SKIP_ABSENT=0
while (( $# )); do
  case "$1" in
    --db-source) DB_SOURCE="${2:?}"; shift ;;
    --stamp)     STAMP="${2:?}"; shift ;;
    --only)      ONLY="${2:?}"; shift ;;
    --pvc)       PVC_ONLY="${2:?}"; DO_DB=0; shift ;;
    --skip-db)   DO_DB=0 ;;
    --skip-pvc)  DO_PVC=0 ;;
    --dry-run)   DRY_RUN=1 ;;
    --skip-absent) SKIP_ABSENT=1 ;;
    -h|--help)   sed -n '2,39p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ $DB_SOURCE == r2 || $DB_SOURCE == orico ]] || { echo "--db-source must be r2 or orico" >&2; exit 2; }

# ── what to restore (mirrors pre-wipe-backup.sh) ────────────────────────────
# CNPG: "<namespace>:<database>"; the Cluster is <namespace>-db-production-cnpg-v1
DATABASES=(
  "firefly-iii:firefly-iii"
  "immich:immich"
  "n8n:n8n"
  "sparkyfitness:sparkyfitness_db"
)

PVC_SETS=(
  "audiobookshelf:audiobookshelf-audiobooks audiobookshelf-config audiobookshelf-metadata"
  "firefly-iii:firefly-iii-upload-pvc"
  "homarr:homarr-appdata"
  "linkding:linkding-data-pvc"
  "movietime:jellyfin-config-pvc navidrome-data-pvc prowlarr-config-pvc radarr-config-pvc rdt-client-config-pvc seerr-config-pvc sonarr-config-pvc"
  "n8n:n8n-data-pvc"
  "sparkyfitness:sparkyfitness-data-pvc"
  "suwayomi:suwayomi-downloads-pvc suwayomi-files-pvc"
)

# Scaled to 0 while their database or volumes are replaced. Immich has no PVC
# to restore but its server must not hold the database open during the drop.
COLD_WORKLOADS=(
  "audiobookshelf:audiobookshelf"
  "firefly-iii:firefly-iii"
  "homarr:homarr"
  "immich:immich-server immich-machine-learning"
  "linkding:linkding"
  "movietime:jellyfin navidrome prowlarr radarr rdt-client seerr sonarr"
  "n8n:n8n"
  "sparkyfitness:sparkyfitness-frontend sparkyfitness-server"
  "suwayomi:suwayomi"
)

# --pvc: keep only the listed PVCs, and only the workloads that own one
# (<deploy>-* naming, e.g. sonarr -> sonarr-config-pvc). Live apps sharing the
# namespace keep running and keep their data.
if [[ -n $PVC_ONLY ]]; then
  filter_sets() {
    local -n arr="$1"; local mode="$2" entry ns item p kept out=()
    for entry in "${arr[@]}"; do
      ns="${entry%%:*}"; kept=""
      for item in ${entry#*:}; do
        for p in ${PVC_ONLY//,/ }; do
          if [[ $mode == pvc && $item == "$p" ]] || [[ $mode == deploy && $p == "$item"-* ]]; then
            kept+="${kept:+ }$item"; break
          fi
        done
      done
      [[ -n $kept ]] && out+=("${ns}:${kept}")
    done
    arr=(${out[@]+"${out[@]}"})
  }
  filter_sets PVC_SETS pvc
  filter_sets COLD_WORKLOADS deploy
  (( ${#PVC_SETS[@]} )) || { echo "--pvc matched no known PVC" >&2; exit 2; }
fi

# `databases` is included because this script flips enableSuperuserAccess on
# the CNPG Clusters. Flux would not revert that field (git never sets it), but
# a reconcile mid-restore is one more moving part nobody needs.
FLUX_KUSTOMIZATIONS=(apps infrastructure-controllers databases)

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$BLD" "$(date -u +%H:%M:%S)" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

selected() {   # is namespace $1 in --only (or is --only unset)?
  [[ -z $ONLY ]] && return 0
  [[ ",${ONLY}," == *",$1,"* ]]
}

SCALED_DOWN=()      # "ns:deploy:replicas"
SUSPENDED=()        # Flux Kustomizations to resume
SUPERUSER_ON=()     # CNPG clusters with enableSuperuserAccess flipped on
TOUCHED_NS=()       # namespaces that may hold a temp PVC / helper pod

cleanup() {
  local rc=$?
  set +e
  local c ns
  for c in "${SUPERUSER_ON[@]}"; do
    ns="${c%%/*}"
    kubectl -n "$ns" patch cluster.postgresql.cnpg.io "${c#*/}" --type=merge \
      -p '{"spec":{"enableSuperuserAccess":false}}' >/dev/null 2>&1 \
      || warn "FAILED to disable superuser access on $c - do it by hand"
  done
  for ns in "${TOUCHED_NS[@]}"; do
    kubectl -n "$ns" delete pod "$HELPER_POD" "${HELPER_POD}-db" --ignore-not-found --wait=false >/dev/null 2>&1
    drop_src "$ns"
  done
  if (( ${#SCALED_DOWN[@]} )); then
    log "scaling workloads back up"
    local entry dep reps
    for entry in "${SCALED_DOWN[@]}"; do
      IFS=: read -r ns dep reps <<<"$entry"
      kubectl -n "$ns" scale deploy "$dep" --replicas="$reps" >/dev/null 2>&1 \
        && echo "    $ns/$dep -> $reps" \
        || warn "FAILED to scale $ns/$dep to $reps - do this by hand"
    done
  fi
  if (( ${#SUSPENDED[@]} )); then
    log "resuming Flux"
    local k
    for k in "${SUSPENDED[@]}"; do
      flux resume kustomization "$k" --timeout=120s >/dev/null 2>&1 \
        && echo "    resumed $k" \
        || warn "FAILED to resume $k - run: flux resume kustomization $k"
    done
  fi
  (( rc != 0 )) && printf '\n%s[fail]%s aborted with status %s\n' "$RED" "$RST" "$rc" >&2
  exit $rc
}
trap cleanup EXIT INT TERM

# ── ORICO access: temporary `local` PV + PVC per namespace, READ-ONLY ───────
ensure_src() {
  local ns="$1"
  [[ " ${TOUCHED_NS[*]} " == *" $ns "* ]] || TOUCHED_NS+=("$ns")
  kubectl apply -f - >/dev/null <<SRC_EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${SRC_PVC}-${ns}
  labels:
    app.kubernetes.io/managed-by: post-rebuild-restore.sh
spec:
  capacity:
    storage: 1Ti
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local
  local:
    path: ${HOST_MOUNT}
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: ${SRC_PVC}
    namespace: ${ns}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [${NODE}]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SRC_PVC}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: post-rebuild-restore.sh
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local
  volumeName: ${SRC_PVC}-${ns}
  resources:
    requests:
      storage: 1Ti
SRC_EOF
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${SRC_PVC}" --timeout=60s >/dev/null \
    || die "ORICO source PVC in $ns never bound"
}

# Poll instead of `kubectl wait --for=...Succeeded`: that one cannot see a
# Failed pod and would sit out its whole timeout.
wait_pod_done() {
  local ns="$1" pod="$2" timeout="$3" phase waited=0
  while (( waited < timeout )); do
    phase="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded) return 0 ;;
      Failed)    return 1 ;;
    esac
    sleep 5; (( waited += 5 ))
  done
  return 1
}

drop_src() {
  # Retain + the PV only names a path: deleting these never touches the disk.
  local ns="$1"
  kubectl -n "$ns" delete pvc "$SRC_PVC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pv "${SRC_PVC}-${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# Root helper pod: ORICO read-only at /orico, each target PVC read-write at
# /dst/<pvc>. Root because extraction must restore the original uid/gid
# (911 for movietime, 1000 elsewhere); baseline PodSecurity allows it.
start_helper() {
  local ns="$1"; shift
  local mounts="" volumes="" p
  for p in "$@"; do
    mounts+="        - { name: v-${p}, mountPath: /dst/${p} }
"
    volumes+="    - name: v-${p}
      persistentVolumeClaim: { claimName: ${p} }
"
  done
  kubectl -n "$ns" delete pod "$HELPER_POD" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -f - >/dev/null <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: post-rebuild-restore.sh
spec:
  restartPolicy: Never
  nodeName: ${NODE}
  containers:
    - name: tar
      image: ${TAR_IMAGE}
      command: ["sleep", "7200"]
      securityContext: { runAsUser: 0, runAsGroup: 0 }
      volumeMounts:
        - { name: orico, mountPath: /orico, readOnly: true }
${mounts}  volumes:
    - name: orico
      persistentVolumeClaim: { claimName: ${SRC_PVC}, readOnly: true }
${volumes}
POD_EOF
  kubectl -n "$ns" wait --for=condition=Ready "pod/${HELPER_POD}" --timeout=300s >/dev/null \
    || die "helper pod in $ns never became ready (kubectl -n $ns describe pod $HELPER_POD)"
}

hx() { local ns="$1"; shift; kubectl -n "$ns" exec "$HELPER_POD" -- "$@"; }

# ── preflight ────────────────────────────────────────────────────────────────
# --skip-absent: drop PVCs that do not exist in the cluster (their app is
# commented out of apps/staging), so a namespace can be restored while some of
# its apps are still off. Without the flag a missing PVC aborts the run.
prune_absent_pvcs() {
  local entry ns p kept out=()
  for entry in "${PVC_SETS[@]}"; do
    ns="${entry%%:*}"; kept=""
    for p in ${entry#*:}; do
      if selected "$ns" && ! kubectl -n "$ns" get pvc "$p" >/dev/null 2>&1; then
        warn "$ns/$p not deployed, skipping (--skip-absent)"
        continue
      fi
      kept+="${kept:+ }$p"
    done
    [[ -n $kept ]] && out+=("${ns}:${kept}")
  done
  PVC_SETS=("${out[@]}")
}

preflight() {
  log "preflight"
  local t
  for t in kubectl flux; do command -v "$t" >/dev/null || die "$t not found"; done
  kubectl version -o json >/dev/null 2>&1 || die "cannot reach the cluster"

  # This script DROPS databases and EMPTIES volumes before restoring. Against
  # the old Omni cluster that would destroy everything newer than the backup.
  local server
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  [[ $server == *omni.siderolabs.io* ]] \
    && die "kube context points at Omni ($server) - this is the OLD cluster. Refusing."
  echo "    apiserver     $server"

  [[ "$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]] \
    || die "node $NODE is not Ready"

  local entry ns
  if (( DO_DB )); then
    for entry in "${DATABASES[@]}"; do
      ns="${entry%%:*}"; selected "$ns" || continue
      kubectl -n "$ns" get cluster.postgresql.cnpg.io "${ns}-db-production-cnpg-v1" >/dev/null 2>&1 \
        || die "CNPG cluster $ns/${ns}-db-production-cnpg-v1 missing - has Flux finished?"
      [[ "$(kubectl -n "$ns" get cluster.postgresql.cnpg.io "${ns}-db-production-cnpg-v1" \
             -o jsonpath='{.status.readyInstances}')" -ge 1 ]] 2>/dev/null \
        || die "CNPG cluster in $ns has no ready instance yet"
      if [[ $DB_SOURCE == r2 ]]; then
        kubectl -n "$ns" get secret r2-backup-creds >/dev/null 2>&1 \
          || die "secret $ns/r2-backup-creds missing (is the databases kustomization reconciled?)"
      fi
    done
  fi
  if (( DO_PVC )); then
    local p
    (( SKIP_ABSENT )) && prune_absent_pvcs
    for entry in "${PVC_SETS[@]}"; do
      ns="${entry%%:*}"; selected "$ns" || continue
      for p in ${entry#*:}; do
        [[ "$(kubectl -n "$ns" get pvc "$p" -o jsonpath='{.status.phase}' 2>/dev/null)" == Bound ]] \
          || die "PVC $ns/$p is not Bound - has Flux finished?"
      done
    done
  fi

  echo "    databases     $( (( DO_DB )) && echo "from ${DB_SOURCE}" || echo skipped)"
  echo "    pvcs          $( (( DO_PVC )) && echo "from ORICO ${HOST_MOUNT}/${BACKUP_SUBDIR}/${STAMP:-<newest>}" || echo skipped)"
  [[ -n $ONLY ]] && echo "    only          ${ONLY}"
  return 0
}

# Newest backup set that has a MANIFEST.txt (a run that died half-way has none).
resolve_stamp() {
  (( DO_PVC )) || [[ $DB_SOURCE == orico ]] || return 0
  local ns="immich"
  ensure_src "$ns"
  start_helper "$ns"
  if [[ -z $STAMP ]]; then
    STAMP="$(hx "$ns" sh -c "cd /orico/${BACKUP_SUBDIR} 2>/dev/null && for d in */; do \
              [ -f \"\${d}MANIFEST.txt\" ] && echo \"\${d%/}\"; done | sort | tail -1")"
    [[ -n $STAMP ]] || die "no complete backup set under ${HOST_MOUNT}/${BACKUP_SUBDIR} - is the ORICO plugged in and mounted?"
  fi
  hx "$ns" test -f "/orico/${BACKUP_SUBDIR}/${STAMP}/MANIFEST.txt" \
    || die "backup set ${STAMP} has no MANIFEST.txt"
  log "backup set ${STAMP}"
  hx "$ns" sed -n '2p' "/orico/${BACKUP_SUBDIR}/${STAMP}/MANIFEST.txt" | sed 's/^/    /'
  kubectl -n "$ns" delete pod "$HELPER_POD" --wait=true --timeout=60s >/dev/null
}

confirm() {
  if (( DRY_RUN )); then
    log "dry run - would restore:"
  else
    printf '\n%sThis REPLACES live data in the new cluster:%s\n' "$BLD" "$RST"
  fi
  local entry ns
  if (( DO_DB )); then
    for entry in "${DATABASES[@]}"; do
      ns="${entry%%:*}"; selected "$ns" || continue
      printf '    db   %-16s %-18s DROP + recreate, then pg_restore (%s)\n' "$ns" "${entry#*:}" "$DB_SOURCE"
    done
  fi
  if (( DO_PVC )); then
    for entry in "${PVC_SETS[@]}"; do
      ns="${entry%%:*}"; selected "$ns" || continue
      printf '    pvc  %-16s %s  (emptied, then extracted)\n' "$ns" "${entry#*:}"
    done
    selected movietime && printf '    pvc  %-16s media-pvc  (folder tree only, %s:%s 2775 - no data)\n' movietime "$MEDIA_UID" "$MEDIA_UID"
  fi
  (( DRY_RUN )) && { log "dry run complete - nothing was changed"; exit 0; }
  printf '%sAffected apps are scaled to 0 for the duration; Ctrl-C scales them back.%s\n' "$YLW" "$RST"
  printf '\nType "restore" to proceed: '
  local reply; read -r reply
  [[ $reply == restore ]] || die "aborted by user"
}

quiesce() {
  log "suspending Flux so it cannot undo the scale-down"
  local k
  for k in "${FLUX_KUSTOMIZATIONS[@]}"; do
    flux suspend kustomization "$k" >/dev/null 2>&1 \
      || die "could not suspend Flux kustomization $k"
    SUSPENDED+=("$k")
    echo "    suspended $k"
  done
  log "scaling workloads to 0"
  local entry ns dep reps sel
  for entry in "${COLD_WORKLOADS[@]}"; do
    ns="${entry%%:*}"; selected "$ns" || continue
    for dep in ${entry#*:}; do
      reps="$(kubectl -n "$ns" get deploy "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
      [[ -n $reps ]] || { warn "$ns/$dep not found, skipping"; continue; }
      [[ $reps == 0 ]] && continue
      kubectl -n "$ns" scale deploy "$dep" --replicas=0 >/dev/null
      SCALED_DOWN+=("${ns}:${dep}:${reps}")
      echo "    $ns/$dep 0 (was $reps)"
    done
  done
  log "waiting for pods to terminate"
  for entry in "${COLD_WORKLOADS[@]}"; do
    ns="${entry%%:*}"; selected "$ns" || continue
    for dep in ${entry#*:}; do
      sel="$(kubectl -n "$ns" get deploy "$dep" -o go-template \
              --template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null \
              | sed 's/,$//' || true)"
      # Missing deployment (app not deployed): pipefail would otherwise make
      # this assignment fail and set -e exit with no message.
      [[ -n $sel ]] || continue
      # A Longhorn RWO volume cannot attach to the helper pod until the app
      # pod has fully let go of it.
      kubectl -n "$ns" wait --for=delete pod -l "$sel" --timeout=300s >/dev/null 2>&1 \
        || die "pods of $ns/$dep did not terminate"
    done
  done
}

# ── databases ────────────────────────────────────────────────────────────────
#
# Runs as the CNPG superuser (enabled just for this): extensions such as
# immich's `vector` can only be created by a superuser, and the app owner
# cannot CREATE DATABASE. Ownership still ends up with the app owner via
# --no-owner --role=<owner>, exactly as the original initdb set it up.
#
#   1. DROP DATABASE ... WITH (FORCE) + CREATE DATABASE ... OWNER <owner>
#   2. replay ONLY the dump's CREATE EXTENSION entries, as superuser
#   3. pg_restore everything else as <owner>, one transaction, stop on error
#   4. compare restored table count against the dump's TABLE DATA entries
restore_databases() {
  log "restoring databases (${DB_SOURCE})"
  local entry ns db cluster owner fetch src_mount src_vol dump_path result pg_image
  for entry in "${DATABASES[@]}"; do
    IFS=: read -r ns db <<<"$entry"
    selected "$ns" || continue
    cluster="${ns}-db-production-cnpg-v1"
    owner="$(kubectl -n "$ns" get cluster.postgresql.cnpg.io "$cluster" \
               -o jsonpath='{.spec.bootstrap.initdb.owner}')"
    [[ -n $owner ]] || die "cannot read the database owner from $ns/$cluster"
    pg_image="$(kubectl -n "$ns" get cronjob "${ns}-db-backup" \
                  -o jsonpath='{.spec.jobTemplate.spec.template.spec.initContainers[0].image}' 2>/dev/null || true)"
    pg_image="${pg_image:-$PG_IMAGE_FALLBACK}"
    printf '    %-16s %-18s ' "$ns" "$db"

    kubectl -n "$ns" patch cluster.postgresql.cnpg.io "$cluster" --type=merge \
      -p '{"spec":{"enableSuperuserAccess":true}}' >/dev/null
    SUPERUSER_ON+=("${ns}/${cluster}")
    local i
    for i in $(seq 60); do
      kubectl -n "$ns" get secret "${cluster}-superuser" >/dev/null 2>&1 && break
      sleep 2
    done
    kubectl -n "$ns" get secret "${cluster}-superuser" >/dev/null 2>&1 \
      || die "CNPG never created ${cluster}-superuser"

    if [[ $DB_SOURCE == r2 ]]; then
      fetch="  initContainers:
    - name: fetch
      image: ${RCLONE_IMAGE}
      env:
        - { name: RCLONE_CONFIG_R2_TYPE, value: s3 }
        - { name: RCLONE_CONFIG_R2_PROVIDER, value: Cloudflare }
        - { name: RCLONE_CONFIG_R2_REGION, value: auto }
        # bucket-scoped token: without this rclone 403s on HeadBucket
        - { name: RCLONE_CONFIG_R2_NO_CHECK_BUCKET, value: \"true\" }
        - { name: RCLONE_CONFIG_R2_ENDPOINT, value: ${R2_ENDPOINT} }
        - name: RCLONE_CONFIG_R2_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: r2-backup-creds, key: ACCESS_KEY_ID } }
        - name: RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: r2-backup-creds, key: SECRET_ACCESS_KEY } }
      command: [sh, -c]
      args:
        - |
          set -eu
          f=\$(rclone lsf r2:${R2_BUCKET}/${ns}/ --files-only | grep '\\.dump\$' | sort | tail -1)
          [ -n \"\$f\" ] || { echo 'FATAL: no dump in R2'; exit 1; }
          rclone copyto \"r2:${R2_BUCKET}/${ns}/\$f\" \"/work/\$f\"
          echo \"fetched \$f\"
      volumeMounts:
        - { name: work, mountPath: /work }
"
      src_mount=""; src_vol=""
      dump_path='$(ls /work/*.dump | tail -1)'
    else
      ensure_src "$ns"
      fetch=""
      src_mount="        - { name: orico, mountPath: /orico, readOnly: true }
"
      src_vol="    - name: orico
      persistentVolumeClaim: { claimName: ${SRC_PVC}, readOnly: true }
"
      dump_path="/orico/${BACKUP_SUBDIR}/${STAMP}/db/${ns}__${db}.dump"
    fi

    kubectl -n "$ns" delete pod "${HELPER_POD}-db" --ignore-not-found --wait=true >/dev/null 2>&1
    kubectl apply -f - >/dev/null <<PGPOD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}-db
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: post-rebuild-restore.sh
spec:
  restartPolicy: Never
  nodeName: ${NODE}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
${fetch}  containers:
    - name: restore
      image: ${pg_image}
      env:
        - { name: PGHOST, value: ${cluster}-rw }
        - name: PGUSER
          valueFrom: { secretKeyRef: { name: ${cluster}-superuser, key: username } }
        - name: PGPASSWORD
          valueFrom: { secretKeyRef: { name: ${cluster}-superuser, key: password } }
      command: [bash, -c]
      args:
        - |
          set -euo pipefail
          f="${dump_path}"
          [ -s "\$f" ] || { echo "FATAL: dump \$f missing or empty"; exit 1; }
          if [ -f /orico/${BACKUP_SUBDIR}/${STAMP}/MANIFEST.txt ] && [ "${DB_SOURCE}" = orico ]; then
            ( cd /orico/${BACKUP_SUBDIR}/${STAMP} && grep " ./db/${ns}__${db}.dump\$" MANIFEST.txt | sha256sum -c --quiet ) \
              || { echo "FATAL: checksum mismatch"; exit 1; }
          fi
          pg_restore --list "\$f" > /work/full.list
          expect=\$(grep -c ' TABLE DATA ' /work/full.list || true)
          psql -v ON_ERROR_STOP=1 -qd postgres \
            -c 'DROP DATABASE IF EXISTS "${db}" WITH (FORCE)' \
            -c 'CREATE DATABASE "${db}" OWNER "${owner}"'
          # The client may be newer than the server (dumps are written by the
          # backup CronJob's image: pg 18, servers: pg 16). pg_restore 18 sends
          # "SET transaction_timeout" even on a direct -d connection, and a 16
          # server rejects it. So render SQL with pg_restore and feed it to
          # psql, dropping that one session setting (it only sets the default).
          render() { pg_restore -f - "\$@" "\$f" | sed '/^SET transaction_timeout = /d'; }
          # Extensions first, as superuser - keeps their WITH SCHEMA clause.
          grep -E '^[0-9]+; [0-9]+ [0-9]+ EXTENSION ' /work/full.list > /work/ext.list || true
          if [ -s /work/ext.list ]; then
            render --no-owner -L /work/ext.list | psql -v ON_ERROR_STOP=1 -qd "${db}" >/dev/null
          fi
          # Everything else as the owner, in one transaction. Extension rows
          # (and their COMMENTs, which only the extension owner may set) are
          # excluded.
          grep -v -E ' EXTENSION ' /work/full.list > /work/rest.list
          render --no-owner --no-acl --role="${owner}" -L /work/rest.list \
            | psql -v ON_ERROR_STOP=1 --single-transaction -qd "${db}" >/dev/null
          got=\$(psql -tAd "${db}" -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
          echo "RESULT \${got} \${expect} \$(basename "\$f")"
          [ "\$got" -ge "\$expect" ] || { echo "FATAL: only \$got of \$expect tables"; exit 1; }
      volumeMounts:
        - { name: work, mountPath: /work }
${src_mount}  volumes:
    - name: work
      emptyDir: { sizeLimit: 2Gi }
${src_vol}
PGPOD_EOF
    [[ " ${TOUCHED_NS[*]} " == *" $ns "* ]] || TOUCHED_NS+=("$ns")
    if ! wait_pod_done "$ns" "${HELPER_POD}-db" 1800; then
      printf '%sFAILED%s\n' "$RED" "$RST"
      kubectl -n "$ns" logs "${HELPER_POD}-db" --all-containers 2>&1 | tail -15 >&2
      die "restore failed for $ns/$db (pod left behind for inspection until the script exits)"
    fi
    result="$(kubectl -n "$ns" logs "${HELPER_POD}-db" -c restore 2>/dev/null | grep '^RESULT' | tail -1 || true)"
    [[ -n $result ]] || die "restore pod for $ns/$db finished but printed no RESULT line - check: kubectl -n $ns logs ${HELPER_POD}-db -c restore"
    kubectl -n "$ns" delete pod "${HELPER_POD}-db" --ignore-not-found --wait=false >/dev/null 2>&1
    read -r _ got expect file <<<"$result"
    printf '%s%s tables%s (dump has %s)  %s  [%s]\n' "$GRN" "$got" "$RST" "$expect" "$file" "${pg_image##*:}"

    kubectl -n "$ns" patch cluster.postgresql.cnpg.io "$cluster" --type=merge \
      -p '{"spec":{"enableSuperuserAccess":false}}' >/dev/null
    local keep=() c
    for c in "${SUPERUSER_ON[@]}"; do [[ $c == "${ns}/${cluster}" ]] || keep+=("$c"); done
    SUPERUSER_ON=(${keep[@]+"${keep[@]}"})
  done
}

# ── PVCs ─────────────────────────────────────────────────────────────────────
restore_pvcs() {
  log "restoring PVCs from ${STAMP}"
  local entry ns pvcs p out
  local base="/orico/${BACKUP_SUBDIR}/${STAMP}"
  for entry in "${PVC_SETS[@]}"; do
    ns="${entry%%:*}"; selected "$ns" || continue
    read -r -a pvcs <<<"${entry#*:}"
    echo "  ${BLD}${ns}${RST}"
    ensure_src "$ns"
    if [[ $ns == movietime ]]; then
      start_helper "$ns" "${pvcs[@]}" media-pvc
    else
      start_helper "$ns" "${pvcs[@]}"
    fi
    for p in "${pvcs[@]}"; do
      printf '    %-28s ' "$p"
      # One shell per PVC: checksum against the MANIFEST, empty the target,
      # extract with the ORIGINAL numeric uid/gid, then count entries back.
      if ! out="$(hx "$ns" bash -c "
            set -euo pipefail
            a='./pvc/${ns}/${p}.tar.gz'
            cd '${base}'
            [ -f \"\$a\" ] || { echo 'archive missing'; exit 1; }
            grep \" \$a\\\$\" MANIFEST.txt | sha256sum -c --quiet || { echo 'checksum mismatch'; exit 1; }
            want=\$(tar -tzf \"\$a\" | grep -cv '^\\./\$' || true)
            find '/dst/${p}' -mindepth 1 -delete
            tar --numeric-owner -xzpf \"\$a\" -C '/dst/${p}'
            got=\$(find '/dst/${p}' -mindepth 1 | wc -l)
            echo \"\$got \$want \$(du -sh '/dst/${p}' | cut -f1)\"
          " 2>&1)"; then
        printf '%sFAILED%s\n' "$RED" "$RST"
        die "$ns/$p: $(tail -1 <<<"$out")"
      fi
      read -r got want size <<<"$(tail -1 <<<"$out")"
      if [[ $got == "$want" ]]; then
        printf '%s%s%s  %s entries\n' "$GRN" "$size" "$RST" "$got"
      else
        printf '%s%s%s  %s of %s entries (hard links count once - check)\n' "$YLW" "$size" "$RST" "$got" "$want"
      fi
    done
    if [[ $ns == movietime ]]; then
      printf '    %-28s ' "media-pvc"
      # Fresh, empty volume: the root is root:root 0755 and every app writing
      # here runs as 911. Rebuild the tree the *arr apps expect; never recurse.
      hx "$ns" bash -c "
        set -e
        for d in /dst/media-pvc /dst/media-pvc/media /dst/media-pvc/media/movies \
                 /dst/media-pvc/media/tv /dst/media-pvc/media/music /dst/media-pvc/torrents; do
          mkdir -p \"\$d\"; chown ${MEDIA_UID}:${MEDIA_UID} \"\$d\"; chmod 2775 \"\$d\"
        done" >/dev/null
      printf '%sfolder tree%s  media/{movies,tv,music} torrents  %s:%s 2775\n' "$GRN" "$RST" "$MEDIA_UID" "$MEDIA_UID"
    fi
    kubectl -n "$ns" delete pod "$HELPER_POD" --wait=true --timeout=120s >/dev/null
    drop_src "$ns"
  done
}

summary() {
  printf '\n%s%s restore complete%s\n' "$GRN" "$BLD" "$RST"
  cat <<NEXT

Apps scale back up and Flux resumes as this script exits. Then check by hand:

  - every app through its Cloudflare hostname; log in to Firefly and look at
    account balances, open an Immich album, start a Jellyfin stream
  - Sonarr/Radarr: Settings > Media Management root folders still point at
    /data/media/{tv,movies}; the media itself must be re-downloaded
  - tomorrow 02:00-02:45: confirm the nightly dumps land again
      rclone ls r2:${R2_BUCKET}/
NEXT
}

preflight
(( DRY_RUN )) || resolve_stamp
confirm
quiesce
(( DO_DB ))  && restore_databases
(( DO_PVC )) && restore_pvcs
summary
