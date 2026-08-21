#!/usr/bin/env bash
# Runs ON the build node (launched detached by build-bare-metal-qcow2-image.sh).
# Bakes the golden qcow2 with the same recipe as the Hetzner Packer snapshot
# (base-image-qemu.pkr.hcl) and uploads it to the R2 dev bucket.
#
#   sudo IMAGE_ID=dev-06-07-2026-14-30-9f3a2c \
#     SOURCE_COMMIT=<40-hex> INPUTS_SHA256=<64-hex> \
#     [REPO_DIR=/home/ubuntu/ariana-ide-rewrite-proto] \
#     ./build-bare-metal-qcow2-image-remote.sh
#
# Requires /etc/ascii/r2-qemu-images.env (mode 600) on the node:
#   R2_ENDPOINT=...
#   R2_QEMU_IMAGES_ACCESS_KEY_ID=...
#   R2_QEMU_IMAGES_SECRET_ACCESS_KEY=...
#   R2_QEMU_IMAGES_BUCKET_DEV=qemu-base-images-dev
#   R2_QEMU_IMAGES_BUCKET_PROD=qemu-base-images-prod
#
# Images are ALWAYS uploaded to the dev bucket; promotion to prod is a separate
# explicit step (promote-bare-metal-qcow2-image.sh).
set -euo pipefail

log() { printf '\033[1;32m[build-image]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[build-image] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "run as root (needs /dev/kvm + system-wide tool installs)"

# systemd-run units have no $HOME; packer/aws need one for their config dirs.
export HOME="${HOME:-/root}"

IMAGE_ID="${IMAGE_ID:-}"
[ -n "$IMAGE_ID" ] || fail "IMAGE_ID is required (e.g. dev-06-07-2026-14-30-9f3a2c)"
[[ "$IMAGE_ID" =~ ^dev-[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-f0-9]{6}$ ]] \
  || fail "invalid immutable dev image id: $IMAGE_ID"

REPO_DIR="${REPO_DIR:-/home/ubuntu/ariana-ide-rewrite-proto}"
SOURCE_COMMIT="${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
INPUTS_SHA256="${INPUTS_SHA256:?INPUTS_SHA256 is required}"
[[ "$SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ ]] || fail "invalid source commit"
[[ "$INPUTS_SHA256" =~ ^[a-f0-9]{64}$ ]] || fail "invalid build-input digest"
AGENT_SERVER_TAG="${AGENT_SERVER_TAG:?AGENT_SERVER_TAG is required}"
BOX_CLI_TAG="${BOX_CLI_TAG:?BOX_CLI_TAG is required}"
[[ "$AGENT_SERVER_TAG" =~ ^agent-server-v[A-Za-z0-9._-]+$ ]] || fail "invalid agent-server tag"
[[ "$BOX_CLI_TAG" =~ ^box-cli-v[A-Za-z0-9._-]+$ ]] || fail "invalid Box CLI tag"
AGENTS_SERVER_DIR="$REPO_DIR/backend/agents-server"
[ -f "$AGENTS_SERVER_DIR/base-image-qemu.pkr.hcl" ] || fail "no base-image-qemu.pkr.hcl under $AGENTS_SERVER_DIR (rsync the repo first)"

R2_ENV_FILE=/etc/ascii/r2-qemu-images.env
[ -f "$R2_ENV_FILE" ] || fail "$R2_ENV_FILE missing — create it with the R2 token + bucket names (see header)"
SOURCES_ENV_FILE=/etc/ascii/image-build-sources.env
[ -f "$SOURCES_ENV_FILE" ] || fail "$SOURCES_ENV_FILE missing (versioned UBUNTU_CLOUD_IMAGE_URL, UBUNTU_CLOUD_IMAGE_SHA256, CODEX_VERSION)"
set -a
# shellcheck disable=SC1090
. "$R2_ENV_FILE"
# shellcheck disable=SC1090
. "$SOURCES_ENV_FILE"
set +a
for v in R2_ENDPOINT R2_QEMU_IMAGES_ACCESS_KEY_ID R2_QEMU_IMAGES_SECRET_ACCESS_KEY R2_QEMU_IMAGES_BUCKET_DEV; do
  [ -n "${!v:-}" ] || fail "$v missing from $R2_ENV_FILE"
done
for v in UBUNTU_CLOUD_IMAGE_URL UBUNTU_CLOUD_IMAGE_SHA256 CODEX_VERSION; do
  [ -n "${!v:-}" ] || fail "$v missing from $SOURCES_ENV_FILE"
done
[[ "$UBUNTU_CLOUD_IMAGE_URL" != */current/* ]] || fail "Ubuntu source URL must be versioned, not /current/"
[[ "$UBUNTU_CLOUD_IMAGE_SHA256" =~ ^[a-f0-9]{64}$ ]] || fail "invalid Ubuntu source SHA-256"
[[ "$CODEX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "CODEX_VERSION must be exact"

export AWS_ACCESS_KEY_ID="$R2_QEMU_IMAGES_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_QEMU_IMAGES_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto

LOG_DIR=/var/log/ascii
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/image-build-$IMAGE_ID.log"
exec > >(tee -a "$LOG_FILE") 2>&1

WORK_DIR="/var/lib/ascii/image-builds/$IMAGE_ID"
CACHE_DIR=/var/lib/ascii/image-builds/cache
PACKER_VERSION=1.11.2
PACKER_LINUX_AMD64_SHA256=ced13efc257d0255932d14b8ae8f38863265133739a007c430cae106afcfc45a

# Upload the build log even on failure so every run is inspectable from R2.
upload_log() {
  aws s3 cp --endpoint-url "$R2_ENDPOINT" "$LOG_FILE" \
    "s3://$R2_QEMU_IMAGES_BUCKET_DEV/logs/$IMAGE_ID.log" >/dev/null 2>&1 || true
}
trap upload_log EXIT

# One build at a time per node (same rule as VM provisioning).
exec 9>/var/lock/ascii-image-build.lock
flock -n 9 || fail "another image build is already running on this node"

log "image=$IMAGE_ID repo=$REPO_DIR work=$WORK_DIR"

log "ensuring build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-system-x86 qemu-utils xorriso unzip curl openssl jq >/dev/null

if ! command -v packer >/dev/null 2>&1 \
  || [ "$(packer version 2>/dev/null | head -n1)" != "Packer v$PACKER_VERSION" ]; then
  log "installing packer $PACKER_VERSION"
  curl -fsSL -o /tmp/packer.zip \
    "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip"
  printf '%s  %s\n' "$PACKER_LINUX_AMD64_SHA256" /tmp/packer.zip | sha256sum -c -
  unzip -o -q /tmp/packer.zip -d /usr/local/bin
  rm -f /tmp/packer.zip
fi
packer version

if ! command -v aws >/dev/null 2>&1; then
  log "installing aws cli v2"
  curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
  /tmp/awscliv2/aws/install --update >/dev/null
  rm -rf /tmp/awscliv2 /tmp/awscliv2.zip
fi

log "verifying R2 access to bucket $R2_QEMU_IMAGES_BUCKET_DEV (fail fast before the ~40min bake)"
aws s3api head-bucket --endpoint-url "$R2_ENDPOINT" --bucket "$R2_QEMU_IMAGES_BUCKET_DEV" \
  || fail "cannot reach bucket $R2_QEMU_IMAGES_BUCKET_DEV with the configured token"
if aws s3api head-object --endpoint-url "$R2_ENDPOINT" --bucket "$R2_QEMU_IMAGES_BUCKET_DEV" \
  --key "$IMAGE_ID.qcow2" >/dev/null 2>&1 \
  || aws s3api head-object --endpoint-url "$R2_ENDPOINT" --bucket "$R2_QEMU_IMAGES_BUCKET_DEV" \
  --key "$IMAGE_ID.qcow2.sha256" >/dev/null 2>&1; then
  fail "immutable image id already exists: $IMAGE_ID"
fi
lock_file="$(mktemp)"
printf 'image_id=%s\nsource_commit=%s\ninputs_sha256=%s\nclaimed_at=%s\n' \
  "$IMAGE_ID" "$SOURCE_COMMIT" "$INPUTS_SHA256" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock_file"
aws s3api put-object --endpoint-url "$R2_ENDPOINT" --bucket "$R2_QEMU_IMAGES_BUCKET_DEV" \
  --key "locks/$IMAGE_ID" --body "$lock_file" --if-none-match '*' >/dev/null \
  || fail "immutable image id is already claimed: $IMAGE_ID"
rm -f "$lock_file"

mkdir -p "$CACHE_DIR"
CLOUDIMG="$CACHE_DIR/noble-server-cloudimg-amd64-$UBUNTU_CLOUD_IMAGE_SHA256.img"
if [ ! -f "$CLOUDIMG" ]; then
  log "downloading pinned noble cloud image: $UBUNTU_CLOUD_IMAGE_URL"
  curl -fsSL -o "$CLOUDIMG.tmp" "$UBUNTU_CLOUD_IMAGE_URL"
  printf '%s  %s\n' "$UBUNTU_CLOUD_IMAGE_SHA256" "$CLOUDIMG.tmp" | sha256sum -c -
  mv "$CLOUDIMG.tmp" "$CLOUDIMG"
fi
printf '%s  %s\n' "$UBUNTU_CLOUD_IMAGE_SHA256" "$CLOUDIMG" | sha256sum -c -
qemu-img info "$CLOUDIMG" | head -3

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

log "generating ephemeral build SSH key (removed from image in the seal step)"
ssh-keygen -q -t ed25519 -N '' -f "$WORK_DIR/build-key"

PLATFORM_ASSETS="$WORK_DIR/platform-assets"
mkdir -p "$PLATFORM_ASSETS"
download_release_asset() {
  local tag="$1" asset="$2" output="$3" release checksums expected actual
  release="$(curl -LfsS --retry 5 --retry-all-errors \
    "https://api.github.com/repos/ariana-dot-dev/agent-server/releases/tags/$tag")"
  jq -e '.draft == false and .immutable == true' <<<"$release" >/dev/null \
    || fail "$tag is not a published immutable GitHub release"
  checksums="$(curl -LfsS --retry 5 --retry-all-errors \
    "https://github.com/ariana-dot-dev/agent-server/releases/download/$tag/SHA256SUMS")"
  expected="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1; exit }' <<<"$checksums")"
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || fail "$tag has no checksum for $asset"
  curl -LfsS --retry 5 --retry-all-errors \
    "https://github.com/ariana-dot-dev/agent-server/releases/download/$tag/$asset" -o "$output"
  actual="$(sha256sum "$output" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || fail "$tag/$asset checksum mismatch"
  printf '%s' "$actual"
}
log "downloading exact platform assets for the immutable image"
AGENT_SERVER_SHA256="$(download_release_asset "$AGENT_SERVER_TAG" ascii-agents-server-linux-x64 "$PLATFORM_ASSETS/ascii-agents-server")"
BOX_CLI_SHA256="$(download_release_asset "$BOX_CLI_TAG" box-linux-x64 "$PLATFORM_ASSETS/box")"
chmod 0755 "$PLATFORM_ASSETS/ascii-agents-server" "$PLATFORM_ASSETS/box"
jq -n --arg agentServerTag "$AGENT_SERVER_TAG" --arg agentServerSha256 "$AGENT_SERVER_SHA256" \
  --arg boxCliTag "$BOX_CLI_TAG" --arg boxCliSha256 "$BOX_CLI_SHA256" \
  '{version:1,agentServer:{tag:$agentServerTag,sha256:$agentServerSha256,asset:"ascii-agents-server"},boxCli:{tag:$boxCliTag,sha256:$boxCliSha256,asset:"box"}}' \
  > "$PLATFORM_ASSETS/manifest.json"

log "running packer (this is the ~30-45min part: install-all-deps + fswatch + moonlight builds)"
cd "$AGENTS_SERVER_DIR"
packer init base-image-qemu.pkr.hcl
PACKER_LOG=0 packer build \
  -var "image_id=$IMAGE_ID" \
  -var "cloudimg_path=$CLOUDIMG" \
  -var "cloudimg_sha256=$UBUNTU_CLOUD_IMAGE_SHA256" \
  -var "cloudimg_source_url=$UBUNTU_CLOUD_IMAGE_URL" \
  -var "codex_version=$CODEX_VERSION" \
  -var "platform_assets_directory=$PLATFORM_ASSETS" \
  -var "ssh_public_key=$(cat "$WORK_DIR/build-key.pub")" \
  -var "ssh_private_key_file=$WORK_DIR/build-key" \
  -var "output_directory=$WORK_DIR/out" \
  base-image-qemu.pkr.hcl

RAW="$WORK_DIR/out/$IMAGE_ID.qcow2"
[ -f "$RAW" ] || fail "packer finished but $RAW is missing"

FINAL="$WORK_DIR/$IMAGE_ID.qcow2"
log "compressing qcow2 ($(du -h "$RAW" | cut -f1) raw)"
qemu-img convert -c -O qcow2 "$RAW" "$FINAL"
rm -rf "$WORK_DIR/out"
log "compressed size: $(du -h "$FINAL" | cut -f1)"

log "checksumming"
(cd "$WORK_DIR" && sha256sum "$IMAGE_ID.qcow2" > "$IMAGE_ID.qcow2.sha256")

log "uploading to s3://$R2_QEMU_IMAGES_BUCKET_DEV/"
IMAGE_SHA256="$(awk '{print $1}' "$WORK_DIR/$IMAGE_ID.qcow2.sha256")"
metadata="source-commit=$SOURCE_COMMIT,inputs-sha256=$INPUTS_SHA256,image-sha256=$IMAGE_SHA256,agent-server-tag=$AGENT_SERVER_TAG,agent-server-sha256=$AGENT_SERVER_SHA256,box-cli-tag=$BOX_CLI_TAG,box-cli-sha256=$BOX_CLI_SHA256"
aws s3 cp --endpoint-url "$R2_ENDPOINT" --metadata "$metadata" \
  "$FINAL" "s3://$R2_QEMU_IMAGES_BUCKET_DEV/$IMAGE_ID.qcow2"
aws s3 cp --endpoint-url "$R2_ENDPOINT" --metadata "$metadata" \
  "$WORK_DIR/$IMAGE_ID.qcow2.sha256" "s3://$R2_QEMU_IMAGES_BUCKET_DEV/$IMAGE_ID.qcow2.sha256"
head="$(aws s3api head-object --endpoint-url "$R2_ENDPOINT" --bucket "$R2_QEMU_IMAGES_BUCKET_DEV" --key "$IMAGE_ID.qcow2")"
[ "$(jq -r '.Metadata["source-commit"] // empty' <<<"$head")" = "$SOURCE_COMMIT" ] \
  && [ "$(jq -r '.Metadata["inputs-sha256"] // empty' <<<"$head")" = "$INPUTS_SHA256" ] \
  && [ "$(jq -r '.Metadata["image-sha256"] // empty' <<<"$head")" = "$IMAGE_SHA256" ] \
  && [ "$(jq -r '.Metadata["agent-server-tag"] // empty' <<<"$head")" = "$AGENT_SERVER_TAG" ] \
  && [ "$(jq -r '.Metadata["agent-server-sha256"] // empty' <<<"$head")" = "$AGENT_SERVER_SHA256" ] \
  && [ "$(jq -r '.Metadata["box-cli-tag"] // empty' <<<"$head")" = "$BOX_CLI_TAG" ] \
  && [ "$(jq -r '.Metadata["box-cli-sha256"] // empty' <<<"$head")" = "$BOX_CLI_SHA256" ] \
  || fail "uploaded image provenance metadata mismatch"

rm -rf "$WORK_DIR"

cat <<EOF

── image built + uploaded ─────────────────────────────────────────────
 id:      $IMAGE_ID
 object:  s3://$R2_QEMU_IMAGES_BUCKET_DEV/$IMAGE_ID.qcow2
 log:     s3://$R2_QEMU_IMAGES_BUCKET_DEV/logs/$IMAGE_ID.log
 fetch on any node:   fetch-bare-metal-qcow2-image.sh $IMAGE_ID
 promote to prod:     promote-bare-metal-qcow2-image.sh $IMAGE_ID
───────────────────────────────────────────────────────────────────────
EOF
