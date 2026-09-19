#!/usr/bin/env bash
#
# seed-r2-secret.sh — configure Cloudflare R2 as the CNPG backup destination.
#
# Validates the credentials against R2 FIRST, then writes a SOPS-encrypted
# Secret into each database namespace and substitutes the account/bucket into
# the barmanObjectStore stanzas.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ WHY VALIDATION COMES FIRST                                               │
# │ Adding backup.barmanObjectStore makes CNPG set an archive_command and    │
# │ begin shipping WAL. If the credentials are wrong, archiving FAILS, and   │
# │ Postgres will not recycle WAL it has not archived — it accumulates in    │
# │ pg_wal until the PVC (3–5Gi here) is full, at which point the database   │
# │ stops. Broken backup config does not fail quietly; it takes the database │
# │ down. So: prove the bucket is writable before merging the stanza.        │
# └──────────────────────────────────────────────────────────────────────────┘
#
# ── ONE-TIME MANUAL SETUP (needs a browser) ────────────────────────────────
#
# 1. dash.cloudflare.com -> R2 -> Create bucket (e.g. "pineapple-pg-backups").
#    Location: pick the one nearest you. Leave public access OFF.
# 2. R2 -> Manage API tokens -> Create API token
#      Permission: "Object Read & Write"
#      Scope it to that single bucket, not the whole account.
#    Note the Access Key ID and Secret Access Key (shown once).
# 3. Your account ID is in the R2 sidebar / the S3 endpoint URL.
#
# R2 free tier is 10 GB stored and generous Class A/B operations — the four
# live databases total ~291 MB, so this stays free. Egress is always free on
# R2, which is what you want on the day you actually restore.
#
# Usage:
#   scripts/seed-r2-secret.sh \
#     --account-id <cf account id> --bucket pineapple-pg-backups \
#     --access-key <id> --secret-key <secret>
#
#   scripts/seed-r2-secret.sh ... --validate-only   # just test the credentials
#
set -euo pipefail

AGE_RECIPIENT="age1av8wp2lg5m6anyd94jg9x67st3prnkfnacrtl25ptlzjmc06gqsq0w85c3"
SECRET_NAME="r2-backup-creds"
VALIDATE_NS="immich"           # any namespace will do for the connectivity probe
RCLONE_IMAGE="rclone/rclone:latest"
PROBE_POD="r2-validate"

# Namespaces with a live CNPG cluster (databases/kustomization.yaml enables
# exactly these four; commafeed is commented out and suwayomi is absent).
NAMESPACES=(firefly-iii immich n8n sparkyfitness)

ACCOUNT_ID=""; BUCKET=""; ACCESS_KEY=""; SECRET_KEY=""; VALIDATE_ONLY=0
while (( $# )); do
  case "$1" in
    --account-id)    ACCOUNT_ID="${2:?}"; shift 2 ;;
    --bucket)        BUCKET="${2:?}"; shift 2 ;;
    --access-key)    ACCESS_KEY="${2:?}"; shift 2 ;;
    --secret-key)    SECRET_KEY="${2:?}"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
log() { printf '%s[%s]%s %s\n' "$BLD" "$(date -u +%H:%M:%S)" "$RST" "$*"; }
die() { printf '%s[fail]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

for v in ACCOUNT_ID BUCKET ACCESS_KEY SECRET_KEY; do
  [[ -n "${!v}" ]] || die "--${v,,} is required (see --help)"
done
[[ "${ACCOUNT_ID}" =~ ^[0-9a-f]{32}$ ]] || \
  printf '%s[warn]%s account id does not look like 32 hex chars - double-check it\n' "$YLW" "$RST"

ENDPOINT="https://${ACCOUNT_ID}.r2.cloudflarestorage.com"
command -v sops >/dev/null || die "sops not found"

cleanup() { kubectl -n "$VALIDATE_NS" delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# ── 1. prove the bucket is readable AND writable, from inside the cluster ───
log "validating R2 credentials against ${ENDPOINT}"
kubectl -n "$VALIDATE_NS" delete pod "$PROBE_POD" --ignore-not-found >/dev/null 2>&1
kubectl apply -f - >/dev/null <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  namespace: ${VALIDATE_NS}
spec:
  restartPolicy: Never
  containers:
    - name: rclone
      image: ${RCLONE_IMAGE}
      command: ["sleep", "600"]
      env:
        - name: RCLONE_CONFIG_R2_TYPE
          value: s3
        - name: RCLONE_CONFIG_R2_PROVIDER
          value: Cloudflare
        - name: RCLONE_CONFIG_R2_NO_CHECK_BUCKET
          value: "true"
        - name: RCLONE_CONFIG_R2_ENDPOINT
          value: ${ENDPOINT}
        - name: RCLONE_CONFIG_R2_REGION
          value: auto
        - name: RCLONE_CONFIG_R2_ACCESS_KEY_ID
          value: ${ACCESS_KEY}
        - name: RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
          value: ${SECRET_KEY}
POD_EOF
kubectl -n "$VALIDATE_NS" wait --for=condition=Ready "pod/${PROBE_POD}" --timeout=300s >/dev/null \
  || die "probe pod never became ready"

probe() { kubectl -n "$VALIDATE_NS" exec "$PROBE_POD" -- "$@"; }

probe rclone lsd "r2:${BUCKET}" >/dev/null 2>&1 \
  || die "cannot list r2:${BUCKET} - wrong key, wrong bucket name, or the token is not scoped to it"
echo "    read  OK"

# A read-only token is a classic silent failure: listing works, archiving does
# not. Prove a write actually lands.
probe sh -c "echo pineapple-probe | rclone rcat 'r2:${BUCKET}/.cnpg-write-probe'" >/dev/null 2>&1 \
  || die "bucket is NOT writable - the token needs 'Object Read & Write', not read-only"
probe rclone deletefile "r2:${BUCKET}/.cnpg-write-probe" >/dev/null 2>&1 || true
echo "    write OK"
printf '%s    credentials validated%s\n' "$GRN" "$RST"

(( VALIDATE_ONLY )) && { log "--validate-only: stopping here, nothing written"; exit 0; }

# ── 2. write one SOPS-encrypted Secret per namespace ────────────────────────
log "writing SOPS-encrypted secrets"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; cleanup' EXIT INT TERM
for ns in "${NAMESPACES[@]}"; do
  cat > "${tmp}/plain.yaml" <<SEC_EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${ns}
type: Opaque
stringData:
  ACCESS_KEY_ID: ${ACCESS_KEY}
  SECRET_ACCESS_KEY: ${SECRET_KEY}
  REGION: auto
SEC_EOF
  # Match the repo's existing convention: encrypt only data/stringData so the
  # manifest stays reviewable in a diff.
  sops --encrypt --age "$AGE_RECIPIENT" \
       --encrypted-regex '^(data|stringData)$' \
       "${tmp}/plain.yaml" > "databases/${ns}/r2-credentials.yaml" \
    || die "sops encryption failed for ${ns}"
  echo "    databases/${ns}/r2-credentials.yaml"
done
rm -rf "$tmp"

# ── 3. substitute account/bucket into the backup CronJobs ──────────────────
log "substituting R2 endpoint and bucket into the backup CronJobs"
for ns in "${NAMESPACES[@]}"; do
  f="databases/${ns}/backup-cronjob.yaml"
  [[ -f "$f" ]] || die "$f not found"
  sed -i \
    -e "s|R2_ENDPOINT_PLACEHOLDER|${ENDPOINT}|g" \
    -e "s|R2_BUCKET_PLACEHOLDER|${BUCKET}|g" "$f"
  grep -q 'R2_.*_PLACEHOLDER' "$f" && die "placeholders remain in $f"
  echo "    $f"
done

printf '\n%s%s R2 configured%s\n\n' "$GRN" "$BLD" "$RST"
cat <<NEXT
${BLD}Before committing${RST} — confirm nothing leaked in plaintext:

    git diff --stat
    grep -r '${ACCESS_KEY:0:6}' databases/ || echo 'no plaintext key - good'
    sops --decrypt databases/immich/r2-credentials.yaml | head

${BLD}After Flux reconciles${RST} — do not wait until 02:00 to find out whether it
works. Trigger one immediately:

    flux reconcile kustomization databases --with-source
    kubectl -n firefly-iii create job --from=cronjob/firefly-iii-db-backup r2-test
    kubectl -n firefly-iii logs job/r2-test --all-containers --follow

Expect a TOC-entry count from the dump step and an uploaded file from the
upload step. Then confirm it is really in the bucket, and clean up the test:

    rclone ls r2:${BUCKET}/firefly-iii/
    kubectl -n firefly-iii delete job r2-test

${BLD}Then verify a RESTORE${RST}, which is the only thing that proves a backup:

    rclone copy r2:${BUCKET}/firefly-iii/ /tmp/restore-test/
    createdb scratch && pg_restore -d scratch /tmp/restore-test/*.dump
NEXT
