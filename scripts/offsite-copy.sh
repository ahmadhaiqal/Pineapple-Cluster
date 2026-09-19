#!/usr/bin/env bash
#
# offsite-copy.sh — STEP 2 of the rebuild sequence. Pushes the step-1 backups
# and Immich's irreplaceable originals to an offsite rclone remote.
#
# Why this exists: everything step 1 produced sits on the ORICO USB disk, and
# Immich's 61G of originals live on that same disk. One enclosure failure takes
# the primary data and the backup together. This is the copy that makes them
# independent.
#
# Runs rclone in-cluster (the data is on urial-lab, not reachable from the
# workstation) reaching the disk through a temporary `local` PV — not hostPath,
# which Talos' default PodSecurity "baseline" forbids. See
# scripts/pre-wipe-backup.sh for the same pattern and the reasoning.
#
# WHAT IS COPIED (measured 2026-09-18, /data = /var/mnt/immich):
#   cluster-backups/<stamp>   step-1 pg_dumps + PVC tarballs
#   upload/            61G    ORIGINAL photos and videos - irreplaceable
#   profile/           ~0     user avatars
#   backups/          893M    Immich's own nightly DB dumps (--include-immich-db)
#
# NOT copied by default, because Immich regenerates both from upload/:
#   encoded-video/     34G    transcodes
#   thumbs/           2.3G    thumbnails
# That is ~36G of Drive quota saved, at the cost of CPU time re-transcoding on
# demand after a restore. Pass --include-derived to copy them anyway.
#
# rclone `copy`, never `sync`: sync deletes on the destination to match the
# source. On a backup target that turns a local mistake into remote data loss.
#
# ── BEFORE RUNNING: one-time manual setup (needs a browser) ─────────────────
#
# 1. Create your OWN Google OAuth client. rclone's built-in client_id is shared
#    by every rclone user on earth and is rate-limited into uselessness for a
#    60G upload.
#      console.cloud.google.com -> new project -> APIs & Services
#      -> enable "Google Drive API"
#      -> OAuth consent screen (External, add yourself as a test user)
#      -> Credentials -> Create OAuth client ID -> Desktop app
#      -> note the Client ID and Client secret
#
# 2. Configure the remote locally:
#      rclone config
#        n) new remote, name: gdrive, storage: drive
#        client_id / client_secret: from step 1
#        scope: 1 (full access)  -- "drive.file" also works and is tighter
#        Edit advanced config: n
#        Use web browser to automatically authenticate: y
#    Verify:  rclone lsd gdrive:
#
# 3. Run this script. It reads your local rclone.conf, ships it into the
#    cluster as a short-lived Secret, and deletes it afterwards.
#
# Google Drive limits worth knowing: 750 GB/day upload cap per account, and
# Drive is slow with many small files. Drive has no object-lock, so a bad
# command can still delete the remote copy - keep Drive's trash enabled.
#
# Usage:
#   scripts/offsite-copy.sh --remote gdrive:pineapple
#   scripts/offsite-copy.sh --remote gdrive:pineapple --dry-run
#   scripts/offsite-copy.sh --remote r2:pineapple --include-derived
#   scripts/offsite-copy.sh --remote gdrive:pineapple --only upload
#
set -euo pipefail

NODE="urial-lab"
HOST_MOUNT="/var/mnt/immich"
DEST_PVC="offsite-copy-src"
HELPER_POD="offsite-copy"
CONF_SECRET="offsite-rclone-conf"
NS="immich"
RCLONE_IMAGE="rclone/rclone:latest"

REMOTE=""
RCLONE_CONF="${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}"
STAMP=""
DRY_RUN=0
INCLUDE_DERIVED=0
INCLUDE_IMMICH_DB=0
ONLY=""
BWLIMIT="${BWLIMIT:-}"

while (( $# )); do
  case "$1" in
    --remote)            REMOTE="${2:?--remote needs a value}"; shift 2 ;;
    --conf)              RCLONE_CONF="${2:?}"; shift 2 ;;
    --stamp)             STAMP="${2:?}"; shift 2 ;;
    --only)              ONLY="${2:?}"; shift 2 ;;
    --bwlimit)           BWLIMIT="${2:?}"; shift 2 ;;
    --include-derived)   INCLUDE_DERIVED=1; shift ;;
    --include-immich-db) INCLUDE_IMMICH_DB=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           sed -n '2,64p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$BLD" "$(date -u +%H:%M:%S)" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

cleanup() {
  local rc=$?
  set +e
  kubectl -n "$NS" delete pod "$HELPER_POD" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$NS" delete secret "$CONF_SECRET" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NS" delete pvc "$DEST_PVC" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pv "${DEST_PVC}-${NS}" --ignore-not-found --wait=false >/dev/null 2>&1
  (( rc != 0 )) && printf '\n%s[fail]%s aborted with status %s\n' "$RED" "$RST" "$rc" >&2
  exit $rc
}
trap cleanup EXIT INT TERM

# ── preflight ────────────────────────────────────────────────────────────────
[[ -n "$REMOTE" ]] || die "--remote is required, e.g. --remote gdrive:pineapple"
[[ "$REMOTE" == *:* ]] || die "--remote must look like <remote>:<path>, got '$REMOTE'"
[[ -r "$RCLONE_CONF" ]] || die "rclone config not readable at $RCLONE_CONF (see the header of this script for setup)"

REMOTE_NAME="${REMOTE%%:*}"
grep -q "^\[${REMOTE_NAME}\]" "$RCLONE_CONF" \
  || die "remote '[${REMOTE_NAME}]' is not defined in $RCLONE_CONF"

log "preflight"
command -v kubectl >/dev/null || die "kubectl not found"
kubectl get node "$NODE" >/dev/null 2>&1 || die "node $NODE not found"

# Pick the newest step-1 backup unless told otherwise.
ensure_src() {
  kubectl apply -f - >/dev/null <<DEST_EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${DEST_PVC}-${NS}
  labels:
    app.kubernetes.io/managed-by: offsite-copy.sh
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
    namespace: ${NS}
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
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: offsite-copy.sh
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local
  volumeName: ${DEST_PVC}-${NS}
  resources:
    requests:
      storage: 1Ti
DEST_EOF
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${DEST_PVC}" --timeout=60s >/dev/null \
    || die "source PVC never bound"
}

log "provisioning ORICO access + rclone config"
ensure_src
kubectl -n "$NS" delete secret "$CONF_SECRET" --ignore-not-found >/dev/null 2>&1
kubectl -n "$NS" create secret generic "$CONF_SECRET" \
  --from-file=rclone.conf="$RCLONE_CONF" >/dev/null

kubectl apply -f - >/dev/null <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: offsite-copy.sh
spec:
  restartPolicy: Never
  nodeName: ${NODE}
  containers:
    - name: rclone
      image: ${RCLONE_IMAGE}
      command: ["sleep", "86400"]
      env:
        - name: RCLONE_CONFIG
          value: /conf/rclone.conf
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      volumeMounts:
        - name: src
          mountPath: /src
          readOnly: true
        - name: conf
          mountPath: /conf
          readOnly: true
  volumes:
    - name: src
      persistentVolumeClaim:
        claimName: ${DEST_PVC}
        readOnly: true
    - name: conf
      secret:
        secretName: ${CONF_SECRET}
POD_EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/${HELPER_POD}" --timeout=300s >/dev/null \
  || die "rclone pod never became ready (image pull?)"

rc() { kubectl -n "$NS" exec "$HELPER_POD" -- rclone "$@"; }

log "verifying the remote is reachable"
rc lsd "${REMOTE_NAME}:" >/dev/null 2>&1 \
  || die "cannot list '${REMOTE_NAME}:' from inside the cluster - is the token valid? try 'rclone lsd ${REMOTE_NAME}:' locally"
echo "    ${REMOTE_NAME}: OK"

if [[ -z "$STAMP" ]]; then
  STAMP="$(rc lsf --dirs-only /src/cluster-backups 2>/dev/null | tr -d '/' | sort | tail -1 || true)"
  [[ -n "$STAMP" ]] || warn "no cluster-backups/<stamp> found - run scripts/pre-wipe-backup.sh first (continuing with Immich data only)"
fi

# ── what to copy: "<label>:<source under /src>:<destination suffix>" ────────
JOBS=()
[[ -n "$STAMP" ]] && JOBS+=("step-1 backups:cluster-backups/${STAMP}:cluster-backups/${STAMP}")
JOBS+=("immich originals:upload:immich/upload")
JOBS+=("immich profiles:profile:immich/profile")
(( INCLUDE_IMMICH_DB ))  && JOBS+=("immich own db dumps:backups:immich/immich-db-backups")
(( INCLUDE_DERIVED ))    && JOBS+=("immich transcodes:encoded-video:immich/encoded-video")
(( INCLUDE_DERIVED ))    && JOBS+=("immich thumbnails:thumbs:immich/thumbs")

if [[ -n "$ONLY" ]]; then
  mapfile -t JOBS < <(printf '%s\n' "${JOBS[@]}" | grep -F ":${ONLY}:" || true)
  (( ${#JOBS[@]} )) || die "--only '$ONLY' matched no source (try: upload, profile, backups, encoded-video, thumbs)"
fi

RCLONE_FLAGS=(
  --transfers 4          # Drive rate-limits aggressively; 4 is the safe ceiling
  --checkers 8
  --tpslimit 10          # stay under Drive's API queries-per-second
  --drive-chunk-size 128M
  --fast-list            # far fewer API calls when walking big trees
  --retries 5
  --low-level-retries 20
  --stats 30s
  --stats-one-line
  --progress
)
[[ -n "$BWLIMIT" ]] && RCLONE_FLAGS+=(--bwlimit "$BWLIMIT")
(( DRY_RUN )) && RCLONE_FLAGS+=(--dry-run)

printf '\n%splan%s\n' "$BLD" "$RST"
printf '    remote        %s\n' "$REMOTE"
printf '    stamp         %s\n' "${STAMP:-<none>}"
printf '    derived data  %s\n' "$( (( INCLUDE_DERIVED )) && echo 'INCLUDED' || echo 'skipped (~36G: encoded-video, thumbs)' )"
printf '    mode          %s\n' "$( (( DRY_RUN )) && echo 'dry-run' || echo 'copy (never deletes on the remote)' )"
for j in "${JOBS[@]}"; do printf '    %-22s /src/%s\n' "${j%%:*}" "$(cut -d: -f2 <<<"$j")"; done
echo

if ! (( DRY_RUN )); then
  printf 'Proceed? [y/N] '; read -r reply
  [[ $reply == [yY] ]] || die "aborted by user"
fi

# ── copy ─────────────────────────────────────────────────────────────────────
FAILED=()
for j in "${JOBS[@]}"; do
  label="${j%%:*}"; src="$(cut -d: -f2 <<<"$j")"; dst="$(cut -d: -f3 <<<"$j")"
  if ! rc lsf "/src/${src}" >/dev/null 2>&1; then
    warn "skipping '${label}': /src/${src} does not exist"
    continue
  fi
  log "copying ${label}  ->  ${REMOTE}/${dst}"
  if rc copy "/src/${src}" "${REMOTE}/${dst}" "${RCLONE_FLAGS[@]}"; then
    printf '  %s✓%s %s\n' "$GRN" "$RST" "$label"
  else
    warn "FAILED: $label"; FAILED+=("$label")
  fi
done

# ── verify ───────────────────────────────────────────────────────────────────
if ! (( DRY_RUN )); then
  log "verifying by hash (rclone check)"
  for j in "${JOBS[@]}"; do
    label="${j%%:*}"; src="$(cut -d: -f2 <<<"$j")"; dst="$(cut -d: -f3 <<<"$j")"
    rc lsf "/src/${src}" >/dev/null 2>&1 || continue
    printf '    %-22s ' "$label"
    # --one-way: extra files already on the remote are fine, missing ones are not.
    if rc check "/src/${src}" "${REMOTE}/${dst}" --one-way --fast-list 2>&1 | tail -3 | grep -qE '0 differences|no differences'; then
      printf '%sverified%s\n' "$GRN" "$RST"
    else
      printf '%sMISMATCH - re-run for this source%s\n' "$YLW" "$RST"; FAILED+=("check:${label}")
    fi
  done
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo
if (( ${#FAILED[@]} )); then
  printf '%s%s completed with %s problem(s):%s %s\n' "$RED" "$BLD" "${#FAILED[@]}" "$RST" "${FAILED[*]}"
  printf '%sDo not wipe anything until these are resolved.%s\n' "$YLW" "$RST"
  exit 1
fi
(( DRY_RUN )) && { log "dry run complete - nothing was uploaded"; exit 0; }

printf '%s%s offsite copy complete and hash-verified%s\n\n' "$GRN" "$BLD" "$RST"
cat <<NEXT
You now have 2 copies on 2 media, 1 offsite. ${BLD}Still not safe to wipe.${RST}

  ${BLD}3.${RST} Verify a RESTORE, not just a copy. The gate is proving the data is
     usable, and a hash check does not prove a dump is loadable:
       pg_restore -l ./backup-staging/*/db/firefly-iii__firefly-iii.dump | head
       createdb scratch && pg_restore -d scratch ./backup-staging/*/db/firefly-iii__firefly-iii.dump
     then open Firefly and check an account balance you recognise.

  ${BLD}4.${RST} Physically unplug the ORICO before installing Talos.

  ${BLD}5.${RST} Confirm your SOPS age private key exists off this machine.

Restoring Immich later: put upload/ and profile/ back, restore the database
from the step-1 pg_dump, then let Immich regenerate thumbnails and transcodes
$( (( INCLUDE_DERIVED )) || echo '(they were deliberately not copied)' ).
NEXT
