#!/usr/bin/env bash
# Runs ON a bare-metal node: pulls a baked qcow2 from R2 into
# /var/lib/ascii/images/ for an exact BASE_IMAGE path selected by the backend.
#
#   sudo ./fetch-bare-metal-qcow2-image.sh dev-06-07-2026-14-30-9f3a2c
#   sudo ./fetch-bare-metal-qcow2-image.sh prod-06-07-2026-14-30-9f3a2c
#
# The bucket is chosen by the id prefix (dev-* -> dev bucket, prod-* -> prod
# bucket) — this is how dev vs prod nodes end up on different images.
# Requires /etc/ascii/r2-qemu-images.env (a read token is enough for fetching).
set -euo pipefail

log() { printf '\033[1;32m[fetch-image]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fetch-image] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/image-provenance.sh
source "$SCRIPT_DIR/lib/image-provenance.sh"

[ "$(id -u)" = "0" ] || fail "run as root"

IMAGE_ID="${1:-}"
[ -n "$IMAGE_ID" ] || fail "usage: $(basename "$0") <image-id (dev-...|prod-...)>"
[[ "$IMAGE_ID" =~ ^(dev|prod)-[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-f0-9]{6}$ ]] \
  || fail "invalid immutable image id: $IMAGE_ID"
EXPECTED_AGENT_SERVER_TAG="${AGENT_SERVER_TAG:?AGENT_SERVER_TAG is required}"
EXPECTED_BOX_CLI_TAG="${BOX_CLI_TAG:?BOX_CLI_TAG is required}"
[[ "$EXPECTED_AGENT_SERVER_TAG" =~ ^agent-server-v[A-Za-z0-9._-]+$ ]] || fail "invalid agent-server tag"
[[ "$EXPECTED_BOX_CLI_TAG" =~ ^box-cli-v[A-Za-z0-9._-]+$ ]] || fail "invalid Box CLI tag"

DEST_DIR=/var/lib/ascii/images
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/box-base-$IMAGE_ID.qcow2"
CHECKSUM="$DEST.sha256"
PROVENANCE="$DEST.provenance.json"
exec 9>"$DEST.lock"
flock 9
if [ -f "$DEST" ]; then
  [ -f "$CHECKSUM" ] || fail "cached image has no checksum: $CHECKSUM"
  [ -f "$PROVENANCE" ] || fail "cached image has no provenance: $PROVENANCE"
  validate_image_provenance_file "$PROVENANCE" \
    || fail "cached image provenance is invalid"
  [ "$(jq -r '.agentServerTag' "$PROVENANCE")" = "$EXPECTED_AGENT_SERVER_TAG" ] \
    && [ "$(jq -r '.boxCliTag' "$PROVENANCE")" = "$EXPECTED_BOX_CLI_TAG" ] \
    || fail "cached image platform releases do not match this provisioning request"
  expected="$(awk '{print $1}' "$CHECKSUM")"
  actual="$(sha256sum "$DEST" | awk '{print $1}')"
  [ "$expected" = "$actual" ] \
    && [ "$(jq -r '.imageSha256' "$PROVENANCE")" = "$expected" ] \
    || fail "cached image checksum/provenance mismatch: $DEST"
  log "verified cached image: $DEST"
  exit 0
fi

R2_ENV_FILE=/etc/ascii/r2-qemu-images.env
[ -f "$R2_ENV_FILE" ] || fail "$R2_ENV_FILE missing (R2 token + bucket names)"
set -a
# shellcheck disable=SC1090
. "$R2_ENV_FILE"
set +a

case "$IMAGE_ID" in
  dev-*)  BUCKET="$R2_QEMU_IMAGES_BUCKET_DEV" ;;
  prod-*) BUCKET="$R2_QEMU_IMAGES_BUCKET_PROD" ;;
  *) fail "image id must start with dev- or prod-" ;;
esac
[ -n "${BUCKET:-}" ] || fail "bucket for $IMAGE_ID not set in $R2_ENV_FILE"

export AWS_ACCESS_KEY_ID="$R2_QEMU_IMAGES_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_QEMU_IMAGES_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto

if ! command -v aws >/dev/null 2>&1; then
  log "installing aws cli v2"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq unzip curl >/dev/null
  curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
  /tmp/awscliv2/aws/install --update >/dev/null
  rm -rf /tmp/awscliv2 /tmp/awscliv2.zip
fi

tmp="$(mktemp "$DEST_DIR/.${IMAGE_ID}.XXXXXX.qcow2")"
trap 'rm -f "$tmp" "$CHECKSUM.tmp" "$PROVENANCE.tmp"' EXIT
image_head="$(aws s3api head-object --endpoint-url "$R2_ENDPOINT" --bucket "$BUCKET" --key "$IMAGE_ID.qcow2")" \
  || fail "image object is missing: $IMAGE_ID.qcow2"
checksum_head="$(aws s3api head-object --endpoint-url "$R2_ENDPOINT" --bucket "$BUCKET" --key "$IMAGE_ID.qcow2.sha256")" \
  || fail "checksum object is required: $IMAGE_ID.qcow2.sha256"
source_commit="$(jq -r '.Metadata["source-commit"] // empty' <<<"$image_head")"
inputs_sha256="$(jq -r '.Metadata["inputs-sha256"] // empty' <<<"$image_head")"
metadata_sha256="$(jq -r '.Metadata["image-sha256"] // empty' <<<"$image_head")"
agent_server_tag="$(jq -r '.Metadata["agent-server-tag"] // empty' <<<"$image_head")"
agent_server_sha256="$(jq -r '.Metadata["agent-server-sha256"] // empty' <<<"$image_head")"
box_cli_tag="$(jq -r '.Metadata["box-cli-tag"] // empty' <<<"$image_head")"
box_cli_sha256="$(jq -r '.Metadata["box-cli-sha256"] // empty' <<<"$image_head")"
[[ "$source_commit" =~ ^[a-f0-9]{40}$ ]] && [[ "$inputs_sha256" =~ ^[a-f0-9]{64}$ ]] \
  && [[ "$metadata_sha256" =~ ^[a-f0-9]{64}$ ]] \
  && [[ "$agent_server_sha256" =~ ^[a-f0-9]{64}$ ]] && [[ "$box_cli_sha256" =~ ^[a-f0-9]{64}$ ]] \
  && [ "$agent_server_tag" = "$EXPECTED_AGENT_SERVER_TAG" ] && [ "$box_cli_tag" = "$EXPECTED_BOX_CLI_TAG" ] \
  || fail "image provenance or exact platform release metadata is missing or invalid"
[ "$(jq -r '.Metadata["source-commit"] // empty' <<<"$checksum_head")" = "$source_commit" ] \
  && [ "$(jq -r '.Metadata["inputs-sha256"] // empty' <<<"$checksum_head")" = "$inputs_sha256" ] \
  && [ "$(jq -r '.Metadata["image-sha256"] // empty' <<<"$checksum_head")" = "$metadata_sha256" ] \
  && [ "$(jq -r '.Metadata["agent-server-tag"] // empty' <<<"$checksum_head")" = "$agent_server_tag" ] \
  && [ "$(jq -r '.Metadata["agent-server-sha256"] // empty' <<<"$checksum_head")" = "$agent_server_sha256" ] \
  && [ "$(jq -r '.Metadata["box-cli-tag"] // empty' <<<"$checksum_head")" = "$box_cli_tag" ] \
  && [ "$(jq -r '.Metadata["box-cli-sha256"] // empty' <<<"$checksum_head")" = "$box_cli_sha256" ] \
  || fail "image/checksum provenance metadata mismatch"
image_etag="$(jq -r '.ETag' <<<"$image_head")"
checksum_etag="$(jq -r '.ETag' <<<"$checksum_head")"
log "downloading provenance-bound s3://$BUCKET/$IMAGE_ID.qcow2"
aws s3api get-object --endpoint-url "$R2_ENDPOINT" --bucket "$BUCKET" --key "$IMAGE_ID.qcow2" \
  --if-match "$image_etag" "$tmp" >/dev/null
log "verifying checksum"
aws s3api get-object --endpoint-url "$R2_ENDPOINT" --bucket "$BUCKET" --key "$IMAGE_ID.qcow2.sha256" \
  --if-match "$checksum_etag" "$CHECKSUM.tmp" >/dev/null
expected="$(awk '{print $1}' "$CHECKSUM.tmp")"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]] || fail "invalid checksum manifest"
actual="$(sha256sum "$tmp" | awk '{print $1}')"
[ "$expected" = "$actual" ] && [ "$expected" = "$metadata_sha256" ] || fail "checksum mismatch"
jq -nc --arg sourceCommit "$source_commit" --arg inputsSha256 "$inputs_sha256" --arg imageSha256 "$metadata_sha256" \
  --arg agentServerTag "$agent_server_tag" --arg agentServerSha256 "$agent_server_sha256" \
  --arg boxCliTag "$box_cli_tag" --arg boxCliSha256 "$box_cli_sha256" \
  '{sourceCommit:$sourceCommit,inputsSha256:$inputsSha256,imageSha256:$imageSha256,agentServerTag:$agentServerTag,agentServerSha256:$agentServerSha256,boxCliTag:$boxCliTag,boxCliSha256:$boxCliSha256}' \
  > "$PROVENANCE.tmp"

mv "$CHECKSUM.tmp" "$CHECKSUM"
mv "$PROVENANCE.tmp" "$PROVENANCE"
mv "$tmp" "$DEST"
trap - EXIT
qemu-img info "$DEST" | head -3
log "installed and verified immutable image: $DEST"
