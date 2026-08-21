#!/usr/bin/env bash
# Remove the pre-LUKS copies only after both unattended TPM2 boot and external
# recovery-key escrow have been proven. This is deliberately a separate step.
set -euo pipefail

fail() { printf '[finalize-node-storage-encryption] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[finalize-node-storage-encryption] %s\n' "$*"; }

[ "$(id -u)" = 0 ] || fail 'run as root'
: "${RECOVERY_KEY_FILE:?RECOVERY_KEY_FILE is required}"
: "${CONFIRM_NODE_ID:?CONFIRM_NODE_ID is required}"
[ "${CONFIRM_PLAINTEXT_DESTRUCTION:-}" = DELETE_AFTER_RECOVERY_PROOF ] \
  || fail 'set CONFIRM_PLAINTEXT_DESTRUCTION=DELETE_AFTER_RECOVERY_PROOF'
[[ "$RECOVERY_KEY_FILE" =~ ^/run/ascii-storage-recovery[A-Za-z0-9._-]*$ ]] \
  || fail 'recovery key must use the bounded /run/ascii-storage-recovery* path'
cleanup_recovery_key() { rm -f -- "$RECOVERY_KEY_FILE"; }
trap cleanup_recovery_key EXIT
[ ! -L "$RECOVERY_KEY_FILE" ] && [ -f "$RECOVERY_KEY_FILE" ] \
  && [ "$(stat -c %a "$RECOVERY_KEY_FILE")" = 600 ] \
  && [ "$(stat -c %u "$RECOVERY_KEY_FILE")" = 0 ] \
  || fail 'recovery key must be a root-owned regular mode-600 file'

manifest=/var/lib/ascii/storage-encryption.json
[ -f "$manifest" ] || fail "$manifest is missing"
[ "$(jq -er '.version' "$manifest")" = 1 ] || fail 'unsupported manifest'
[ "$(jq -er '.nodeId' "$manifest")" = "$CONFIRM_NODE_ID" ] || fail 'node confirmation mismatch'
current_boot_id="$(cat /proc/sys/kernel/random/boot_id)"
[ "$(jq -er '.migrationBootId' "$manifest")" != "$current_boot_id" ] \
  || fail 'the node has not rebooted since migration'
proof=/var/lib/ascii/storage-tpm-reboot-proof.json
[ -f "$proof" ] || fail 'TPM-only unattended reboot proof is missing'
[ "$(jq -er '.afterBootId' "$proof")" = "$current_boot_id" ] \
  && [ "$(jq -er '.tpmOnly' "$proof")" = true ] \
  || fail 'TPM-only unattended reboot proof does not match this boot'
container="$(jq -er '.container' "$manifest")"
[ "$container" = /var/lib/ascii-storage.luks ] || fail 'unexpected container path'

for target in /var/lib/ascii /etc/ascii; do
  source="$(findmnt -n -o SOURCE -T "$target")"
  source="${source%%\[*}"
  lsblk -s -n -o TYPE "$source" | grep -qx crypt || fail "$target is not backed by dm-crypt"
done
# ASC-286 rename: migrated nodes run ascii-node-manager.service, unmigrated
# ones still run the legacy agent unit — accept whichever is installed.
node_unit=ascii-node-manager.service
systemctl cat "$node_unit" >/dev/null 2>&1 || node_unit=ascii-baremetal-node-agent.service
systemctl is-active --quiet "$node_unit" || fail 'node manager is not healthy'
root_source="$(findmnt -n -o SOURCE -T /)"
root_source="${root_source%%\[*}"
discard_max="$(lsblk -D -b -n -o DISC-MAX "$root_source" | head -1 | tr -d '[:space:]')"
[[ "$discard_max" =~ ^[0-9]+$ ]] && [ "$discard_max" -gt 0 ] \
  || fail 'root storage does not advertise discard; physical plaintext cleanup cannot proceed'
cryptsetup open --test-passphrase --key-file "$RECOVERY_KEY_FILE" "$container" \
  || fail 'external recovery key does not unlock the container'

if jq -e '.plaintextFinalizedAt != null' "$manifest" >/dev/null; then
  log 'plaintext copies were already finalized'
  exit 0
fi
data_backup="$(jq -er '.plaintextDataBackup' "$manifest")"
credentials_backup="$(jq -er '.plaintextCredentialsBackup' "$manifest")"
[[ "$data_backup" =~ ^/var/lib/ascii\.plaintext-[0-9]{8}T[0-9]{6}Z$ ]] \
  || fail 'unsafe plaintext data backup path'
[[ "$credentials_backup" =~ ^/etc/ascii\.plaintext-[0-9]{8}T[0-9]{6}Z$ ]] \
  || fail 'unsafe plaintext credential backup path'
started_at="$(jq -r '.plaintextFinalizationStartedAt // empty' "$manifest")"
if [ -z "$started_at" ]; then
  tmp="$(mktemp /var/lib/ascii/storage-encryption.json.XXXXXX)"
  jq --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {plaintextFinalizationStartedAt: $startedAt}' "$manifest" > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$manifest"
fi

log 'removing pre-encryption files and discarding their physical extents'
[ ! -d "$data_backup" ] || rm -rf --one-file-system "$data_backup"
[ ! -d "$credentials_backup" ] || rm -rf --one-file-system "$credentials_backup"
sync
fstrim / >/dev/null 2>&1 || fail 'root filesystem discard failed after plaintext removal; retry finalization'

tmp="$(mktemp /var/lib/ascii/storage-encryption.json.XXXXXX)"
jq --arg finalizedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {plaintextFinalizedAt: $finalizedAt, plaintextDataBackup: null, plaintextCredentialsBackup: null}' \
  "$manifest" > "$tmp"
chmod 0600 "$tmp"
mv "$tmp" "$manifest"
log 'plaintext copies removed after TPM2 reboot and external recovery-key proof'
