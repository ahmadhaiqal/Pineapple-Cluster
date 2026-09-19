#!/usr/bin/env bash
#
# pre-wipe-backup.sh — one-time backup of everything not reconstructible from git,
# staged onto the ORICO USB disk (urial-lab /dev/sda1, mounted /var/mnt/immich).
#
# This is STEP 1 of the rebuild sequence. It is additive: it creates a new
# directory on an existing filesystem and writes into it. It does not
# repartition, remount, or modify any Talos machine config.
#
# The ORICO is reached through a temporary `local` PersistentVolume per
# namespace, NOT a hostPath volume. The cluster enforces PodSecurity
# "baseline" by default (an API-server AdmissionConfiguration, not namespace
# labels - most namespaces carry no pod-security label at all), and baseline
# forbids hostPath. A `local` PV is a PVC to the pod, so it is allowed, needs
# no privilege escalation, and needs no change to any namespace's security
# posture. The PVs use reclaimPolicy Retain, so tearing them down at the end
# never touches the data on the disk.
#
#   1. this script                 -> ALL backups (DB dumps + PVC tarballs) on the ORICO
#   2. copy offsite (Drive/R2)     -> 2 copies, 2 media, 1 offsite
#   3. VERIFY A RESTORE            <- the gate on wiping anything
#   4. physically unplug the ORICO
#   5. wipe / rebuild / replug / restore
#
# What is NOT backed up here, deliberately:
#   immich-library (134G)  - lives on the ORICO already; backing it onto its own
#                            disk buys nothing. It needs the offsite copy (step 2).
#   media-pvc      (200Gi) - re-downloadable via Sonarr/Radarr.
#   *-cnpg-v1-*    PVCs    - raw PGDATA; the pg_dump output supersedes it.
#
# Usage:
#   scripts/pre-wipe-backup.sh            # cold: scales apps down for consistency
#   scripts/pre-wipe-backup.sh --hot      # no downtime, SQLite may be inconsistent
#   scripts/pre-wipe-backup.sh --dry-run
#
set -euo pipefail

NODE="urial-lab"
HOST_MOUNT="/var/mnt/immich"          # ORICO mountpoint on the node
DEST_PVC="prewipe-backup-dest"        # temp PVC giving a namespace ORICO access
# NOT "backups": /var/mnt/immich/backups is Immich's OWN automatic database
# dump directory (immich-db-backup-*.sql.gz, nightly at 02:00) and Immich
# enforces its own retention by deleting files in there. Never stage anything
# of ours inside a directory another app prunes.
BACKUP_SUBDIR="cluster-backups"       # -> /var/mnt/immich/cluster-backups/<stamp>
HELPER_IMAGE="alpine:3"
HELPER_POD="prewipe-backup"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL_DIR="${LOCAL_DIR:-./backup-staging/${STAMP}}"

MODE="cold"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --hot)     MODE="hot" ;;
    --cold)    MODE="cold" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ── what to back up ──────────────────────────────────────────────────────────
# CNPG: "<namespace>:<primary pod>:<database>"
DATABASES=(
  "firefly-iii:firefly-iii-db-production-cnpg-v1-2:firefly-iii"
  "immich:immich-db-production-cnpg-v1-1:immich"
  "n8n:n8n-db-production-cnpg-v1-1:n8n"
  "sparkyfitness:sparkyfitness-db-production-cnpg-v1-1:sparkyfitness_db"
)

# PVCs: "<namespace>:<pvc>[ <pvc>...]"
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

# Deployments scaled to 0 in cold mode, so on-disk state is quiescent.
# cloudflared is left running; it holds no state.
COLD_WORKLOADS=(
  "audiobookshelf:audiobookshelf"
  "firefly-iii:firefly-iii"
  "homarr:homarr"
  "linkding:linkding"
  "movietime:jellyfin navidrome prowlarr radarr rdt-client seerr sonarr"
  "n8n:n8n"
  "sparkyfitness:sparkyfitness-frontend sparkyfitness-server"
  "suwayomi:suwayomi"
)

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$BLD" "$(date -u +%H:%M:%S)" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '  %s+ %s%s\n' "$YLW" "$*" "$RST"; else "$@"; fi; }

SCALED_DOWN=()   # "ns:deploy:replicas" recorded for the restore trap
SUSPENDED=()     # Flux Kustomizations suspended for cold mode, resumed by the trap

# Flux Kustomizations that own the COLD_WORKLOADS deployments. Without
# suspending these, `kubectl scale --replicas=0` is undone within the
# reconcile interval (1m0s here) and the "cold" capture silently becomes a
# hot one - apps writing to the very volumes being tarred. Verified
# 2026-09-19: every app above is owned by `apps` EXCEPT n8n, which lives in
# infrastructure/controllers and is owned by `infrastructure-controllers`.
FLUX_KUSTOMIZATIONS=(apps infrastructure-controllers)

cleanup() {
  local rc=$?
  set +e
  if (( ${#SUSPENDED[@]} )); then
    log "resuming Flux reconciliation"
    local k
    for k in "${SUSPENDED[@]}"; do
      flux resume kustomization "$k" --timeout=60s >/dev/null 2>&1 \
        && echo "    resumed $k" \
        || warn "FAILED to resume Flux kustomization $k - run: flux resume kustomization $k"
    done
  fi
  if (( ${#SCALED_DOWN[@]} )); then
    log "restoring scaled-down workloads"
    local entry ns dep reps
    for entry in "${SCALED_DOWN[@]}"; do
      IFS=: read -r ns dep reps <<<"$entry"
      kubectl -n "$ns" scale deploy "$dep" --replicas="$reps" >/dev/null 2>&1 \
        && echo "    restored $ns/$dep -> $reps" \
        || warn "FAILED to restore $ns/$dep to $reps - do this by hand"
    done
  fi
  local leftover
  for leftover in "${PVC_SETS[@]/:*/}" immich; do
    kubectl -n "$leftover" delete pod "$HELPER_POD" --ignore-not-found --wait=false >/dev/null 2>&1
    drop_dest "$leftover"
  done
  (( rc != 0 )) && printf '\n%s[fail]%s aborted with status %s\n' "$RED" "$RST" "$rc" >&2
  exit $rc
}
trap cleanup EXIT INT TERM

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
  log "preflight"
  command -v kubectl >/dev/null || die "kubectl not found"
  kubectl version -o json >/dev/null 2>&1 || die "cannot reach the cluster"
  kubectl get node "$NODE" >/dev/null 2>&1 || die "node $NODE not found"

  local entry ns pod db
  for entry in "${DATABASES[@]}"; do
    IFS=: read -r ns pod db <<<"$entry"
    kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1 \
      || die "CNPG primary $ns/$pod is gone - re-check 'kubectl get clusters.postgresql.cnpg.io -A'"
  done

  local avail
  avail="$(kubectl -n immich get pvc immich-library -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
  [[ -n "$avail" ]] || warn "immich-library PVC not found; ORICO mount assumption may be stale"

  echo "    node          $NODE"
  echo "    ORICO path    ${HOST_MOUNT}/${BACKUP_SUBDIR}/${STAMP}"
  echo "    local copy    ${LOCAL_DIR}  (MANIFEST only; dumps go straight to the ORICO)"
  echo "    mode          ${MODE}$([[ $MODE == cold ]] && echo '  (apps scaled to 0 during PVC capture)')"
  echo "    databases     ${#DATABASES[@]}"
  echo "    pvc groups    ${#PVC_SETS[@]}"
}

confirm() {
  (( DRY_RUN )) && return 0
  if [[ $MODE == cold ]]; then
    printf '\n%sCold mode scales these to 0, captures, then scales back up:%s\n' "$BLD" "$RST"
    local entry ns deps
    for entry in "${COLD_WORKLOADS[@]}"; do
      ns="${entry%%:*}"; deps="${entry#*:}"
      printf '    %-16s %s\n' "$ns" "$deps"
    done
    printf '%sApps are DOWN for the duration. Ctrl-C restores them.%s\n' "$YLW" "$RST"
  fi
  printf '\nProceed? [y/N] '
  read -r reply
  [[ $reply == [yY] ]] || die "aborted by user"
}

# ── ORICO access: a temporary `local` PV + PVC, one per namespace ───────────
# Mirrors the existing immich-library-pv (local.path /var/mnt/immich,
# nodeAffinity urial-lab, storageClassName "local" - note there is no such
# StorageClass object, these are statically bound by volumeName/claimRef).
# Capacity is a formality: Kubernetes does not enforce quota on local PVs.
ensure_dest() {
  local ns="$1"
  kubectl apply -f - >/dev/null <<DEST_EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${DEST_PVC}-${ns}
  labels:
    app.kubernetes.io/managed-by: pre-wipe-backup.sh
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
    name: ${DEST_PVC}
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
  name: ${DEST_PVC}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: pre-wipe-backup.sh
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local
  volumeName: ${DEST_PVC}-${ns}
  resources:
    requests:
      storage: 1Ti
DEST_EOF
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${DEST_PVC}" --timeout=60s >/dev/null \
    || die "destination PVC in $ns never bound"
}

drop_dest() {
  local ns="$1"
  # Retain reclaim policy: deleting these leaves everything on the disk intact.
  kubectl -n "$ns" delete pvc "$DEST_PVC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete pv "${DEST_PVC}-${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ── helper pod: destination PVC at /orico + the namespace's PVCs read-only ──
helper_pod_spec() {
  local ns="$1"; shift
  local pvcs=("$@")
  local mounts="" volumes="" p
  for p in ${pvcs[@]+"${pvcs[@]}"}; do
    mounts+="        - name: pvc-${p}
          mountPath: /src/${p}
          readOnly: true
"
    volumes+="    - name: pvc-${p}
      persistentVolumeClaim:
        claimName: ${p}
        readOnly: true
"
  done
  cat <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: pre-wipe-backup.sh
spec:
  restartPolicy: Never
  nodeName: ${NODE}
  containers:
    - name: tar
      image: ${HELPER_IMAGE}
      command: ["sleep", "3600"]
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      volumeMounts:
        - name: orico
          mountPath: /orico
${mounts}  volumes:
    - name: orico
      persistentVolumeClaim:
        claimName: ${DEST_PVC}
${volumes}
POD_EOF
}

# ── databases: pg_dump -Fc IN-CLUSTER, written straight onto the ORICO ───────
#
# This deliberately does NOT stream the archive through `kubectl exec`.
# The Omni Kubernetes proxy silently truncates exec streams, measured
# 2026-09-19 against this cluster:
#
#     10 MB  -> 10485760 bytes   (intact)
#     50 MB  -> 43855710 bytes   (truncated)
#    100 MB  -> 31743168 bytes   (truncated)
#
# ...each with a ZERO exit status and no error. That is what broke the immich
# dump (247 MB database, 66 MB archive) and it is the same failure mode as the
# silent etcd snapshot. Anything above ~10 MB through the API proxy is
# untrustworthy in both directions, so the dump is produced by a short-lived
# pod on the backup node that reaches the CNPG -rw service over the cluster
# network and writes the archive onto the ORICO directly. Only the one-line
# result is streamed back.
dump_databases() {
  log "dumping ${#DATABASES[@]} databases (in-cluster -> ORICO, never via the API proxy)"
  local entry ns pod db svc img remote result
  remote="/orico/${BACKUP_SUBDIR}/${STAMP}"
  for entry in "${DATABASES[@]}"; do
    IFS=: read -r ns pod db <<<"$entry"
    svc="${pod%-*}-rw"
    printf '    %-16s %-18s ' "$ns" "$db"
    if (( DRY_RUN )); then printf '%s(dry-run)%s\n' "$YLW" "$RST"; continue; fi
    ensure_dest "$ns"
    # Same image as the cluster, so pg_dump is never older than the server.
    img="$(kubectl get cluster.postgresql.cnpg.io -n "$ns" \
             -o jsonpath='{.items[0].spec.imageName}' 2>/dev/null)"
    [[ -n $img ]] || die "could not resolve the postgres image for $ns"
    kubectl -n "$ns" delete pod "${HELPER_POD}-db" --ignore-not-found --wait=true >/dev/null 2>&1
    kubectl apply -f - >/dev/null <<PGPOD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}-db
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: pre-wipe-backup.sh
spec:
  restartPolicy: Never
  nodeName: ${NODE}
  containers:
    - name: pgdump
      image: ${img}
      # The ORICO root is root:root 0755, so the dump pod
      # must be root to create the backup directory - same as the alpine helper
      # pod below. The stock postgres image runs as non-root and gets EACCES.
      # pg_dump, unlike the postgres server, is happy to run as root.
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      env:
        - name: PGUSER
          valueFrom:
            secretKeyRef: { name: ${ns}-db-creds, key: username }
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef: { name: ${ns}-db-creds, key: password }
      command:
        - sh
        - -c
        - |
          set -e
          mkdir -p ${remote}/db
          out=${remote}/db/${ns}__${db}.dump
          pg_dump -Fc --no-owner --no-acl -h ${svc} -d ${db} -f "\$out"
          # A zero exit from pg_dump is not proof the archive is readable, so
          # parse the TOC back. Cheap, and it catches a truncated write.
          toc=\$(pg_restore --list "\$out" | grep -c '^[0-9]' || true)
          [ "\${toc:-0}" -gt 0 ] || { echo "UNREADABLE"; exit 1; }
          echo "RESULT \$(du -h "\$out" | cut -f1) \${toc}"
      volumeMounts:
        - name: orico
          mountPath: /orico
  volumes:
    - name: orico
      persistentVolumeClaim:
        claimName: ${DEST_PVC}
PGPOD_EOF
    if ! kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded \
           "pod/${HELPER_POD}-db" --timeout=1800s >/dev/null 2>&1; then
      printf '\n'
      kubectl -n "$ns" logs "${HELPER_POD}-db" 2>&1 | tail -5 >&2
      kubectl -n "$ns" delete pod "${HELPER_POD}-db" --ignore-not-found --wait=false >/dev/null 2>&1
      die "pg_dump failed for $ns/$db"
    fi
    result="$(kubectl -n "$ns" logs "${HELPER_POD}-db" 2>/dev/null | grep '^RESULT' | tail -1)"
    kubectl -n "$ns" delete pod "${HELPER_POD}-db" --ignore-not-found --wait=false >/dev/null 2>&1
    printf '%s%s%s  (%s TOC entries verified)\n' \
      "$GRN" "$(awk '{print $2}' <<<"$result")" "$RST" "$(awk '{print $3}' <<<"$result")"
  done
}
# ── PVCs: tar inside a helper pod, straight onto the ORICO ──────────────────
scale_down() {
  [[ $MODE == cold ]] || return 0
  log "suspending Flux so it cannot undo the scale-down"
  local k
  for k in "${FLUX_KUSTOMIZATIONS[@]}"; do
    if (( DRY_RUN )); then printf '  %s+ flux suspend kustomization %s%s\n' "$YLW" "$k" "$RST"; continue; fi
    flux suspend kustomization "$k" >/dev/null 2>&1 \
      || die "could not suspend Flux kustomization $k - refusing to run a cold capture Flux will fight"
    SUSPENDED+=("$k")
    echo "    suspended $k"
  done
  log "scaling workloads to 0"
  local entry ns deps dep reps
  for entry in "${COLD_WORKLOADS[@]}"; do
    ns="${entry%%:*}"; deps="${entry#*:}"
    for dep in $deps; do
      reps="$(kubectl -n "$ns" get deploy "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
      [[ -n "$reps" ]] || { warn "$ns/$dep not found, skipping"; continue; }
      [[ "$reps" == "0" ]] && continue
      run kubectl -n "$ns" scale deploy "$dep" --replicas=0
      (( DRY_RUN )) || SCALED_DOWN+=("${ns}:${dep}:${reps}")
      echo "    $ns/$dep 0 (was $reps)"
    done
  done
  (( DRY_RUN )) && return 0
  log "waiting for pods to terminate"
  local sel
  for entry in "${COLD_WORKLOADS[@]}"; do
    ns="${entry%%:*}"
    for dep in ${entry#*:}; do
      # Read the selector off the Deployment; guessing "app=<name>" is wrong for
      # the bjw-s and *arr charts, which label with app.kubernetes.io/name.
      sel="$(kubectl -n "$ns" get deploy "$dep" -o go-template \
              --template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null \
              | sed 's/,$//')"
      [[ -n "$sel" ]] || continue
      kubectl -n "$ns" wait --for=delete pod -l "$sel" --timeout=180s >/dev/null 2>&1 || true
    done
  done
}

backup_pvcs() {
  log "capturing PVCs onto the ORICO"
  local entry ns pvcs remote
  remote="/orico/${BACKUP_SUBDIR}/${STAMP}"
  for entry in "${PVC_SETS[@]}"; do
    ns="${entry%%:*}"
    read -r -a pvcs <<<"${entry#*:}"
    echo "  ${BLD}${ns}${RST}"
    if (( DRY_RUN )); then
      printf '    %s+ helper pod with %s PVC(s)%s\n' "$YLW" "${#pvcs[@]}" "$RST"
      continue
    fi
    ensure_dest "$ns"
    helper_pod_spec "$ns" "${pvcs[@]}" | kubectl apply -f - >/dev/null
    kubectl -n "$ns" wait --for=condition=Ready "pod/${HELPER_POD}" --timeout=180s >/dev/null \
      || die "helper pod in $ns never became ready"
    kubectl -n "$ns" exec "$HELPER_POD" -- mkdir -p "${remote}/pvc/${ns}"
    local p
    for p in "${pvcs[@]}"; do
      printf '    %-28s ' "$p"
      if kubectl -n "$ns" exec "$HELPER_POD" -- \
           sh -c "tar -czf '${remote}/pvc/${ns}/${p}.tar.gz' -C '/src/${p}' . \
                  && du -h '${remote}/pvc/${ns}/${p}.tar.gz' | cut -f1"; then :; else
        die "tar failed for $ns/$p"
      fi
    done
    kubectl -n "$ns" delete pod "$HELPER_POD" --wait=true --timeout=60s >/dev/null
    drop_dest "$ns"
  done
}

# ── manifest: sizes, checksums, and what each artifact restores into ─────────
write_manifest() {
  (( DRY_RUN )) && return 0
  log "writing manifest + checksums"
  local remote="/orico/${BACKUP_SUBDIR}/${STAMP}" ns="immich"
  # Destination PVC only - no app PVCs needed for this pass.
  ensure_dest "$ns"
  helper_pod_spec "$ns" | kubectl apply -f - >/dev/null
  kubectl -n "$ns" wait --for=condition=Ready "pod/${HELPER_POD}" --timeout=180s >/dev/null \
    || die "manifest helper pod never became ready"

  # The DB dumps are already on the ORICO - dump_databases writes them there
  # directly. They are deliberately NOT uploaded through `kubectl exec -i`:
  # the Omni API proxy truncates streams over ~10 MB silently, in BOTH
  # directions, so a 66 MB archive pushed that way would land corrupt.
  kubectl -n "$ns" exec "$HELPER_POD" -- mkdir -p "${remote}/db"

  # NOTE: busybox find (alpine) supports neither -printf nor -exec {} + , so
  # this walks the tree with a read loop instead of GNU findutils idioms.
  kubectl -n "$ns" exec "$HELPER_POD" -- sh -c "
    cd '${remote}' || exit 1
    {
      echo '# pre-wipe backup ${STAMP}'
      echo '# cluster Talos-Pineapple   node ${NODE}   mode ${MODE}'
      echo '#'
      echo '# db/*.dump   pg_dump -Fc, restore with: pg_restore -d <target> <file>'
      echo '# pvc/<ns>/*  tar czf of the PVC root, restore with: tar xzf <file> -C <mount>'
      echo '#'
      echo '# NOT in this backup: immich-library (lives on this same disk - needs'
      echo '# the offsite copy) and media-pvc (re-downloadable).'
      echo
      echo '## contents'
      find . -type f ! -name MANIFEST.txt | sort | while read -r f; do
        printf '%-58s %12s bytes\n' \"\$f\" \"\$(wc -c < \"\$f\")\"
      done
      echo
      echo '## sha256'
      find . -type f ! -name MANIFEST.txt | sort | while read -r f; do
        sha256sum \"\$f\"
      done
    } > MANIFEST.txt
    echo
    echo '## ORICO free space after backup'
    df -h /orico | tail -1
  "
  # LOCAL_DIR is no longer created by dump_databases (the dumps go straight to
  # the ORICO now), so make it here before pulling the manifest down. The
  # manifest is a few KB - safely under the API proxy's truncation threshold.
  mkdir -p "${LOCAL_DIR}"
  kubectl -n "$ns" exec "$HELPER_POD" -- cat "${remote}/MANIFEST.txt" > "${LOCAL_DIR}/MANIFEST.txt"
  kubectl -n "$ns" delete pod "$HELPER_POD" --wait=true --timeout=60s >/dev/null
  drop_dest "$ns"
}

summary() {
  (( DRY_RUN )) && { log "dry run complete - nothing was changed"; return 0; }
  printf '\n%s%s backup complete%s\n' "$GRN" "$BLD" "$RST"
  echo "    ORICO   ${HOST_MOUNT}/${BACKUP_SUBDIR}/${STAMP}"
  echo "    local   ${LOCAL_DIR}  (MANIFEST.txt; the dumps live on the ORICO)"
  cat <<NEXT

${BLD}Not yet safe to wipe.${RST} Remaining:

  ${BLD}2.${RST} Copy offsite. Two copies on one USB enclosure is one failure away
     from zero. The irreplaceable set is the 4 DB dumps plus the Immich
     library (134G, which this script deliberately did not touch because it
     already lives on this disk):
       scripts/offsite-copy.sh --remote gdrive:pineapple
     (use rclone *copy*, never *sync* - sync deletes on the destination to
      match the source, which is the opposite of what a backup target wants)

  ${BLD}3.${RST} ${BLD}Verify a restore.${RST} This is the gate, not step 2:
       createdb scratch && pg_restore -d scratch <ORICO>/db/firefly-iii__firefly-iii.dump
     then actually log in and look at your account balances.

  ${BLD}4.${RST} Physically unplug the ORICO before installing Talos.

  ${BLD}5.${RST} Also confirm your SOPS age private key exists somewhere other than
     \$SOPS_AGE_KEY_FILE on this machine - without it every secrets.yaml in
     this repo is unreadable and the rebuild stalls.
NEXT
}

preflight
confirm
dump_databases
scale_down
backup_pvcs
write_manifest
summary
