#!/usr/bin/env bash
# One-time in-place migration of /var/lib/ascii and /etc/ascii into a LUKS2
# container sealed to this host's TPM2. The recovery key is supplied externally
# and is never copied onto the node.
set -euo pipefail

log() { printf '[encrypt-node-storage] %s\n' "$*"; }
fail() { printf '[encrypt-node-storage] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail 'run as root'
: "${RECOVERY_KEY_FILE:?RECOVERY_KEY_FILE must reference an externally retained recovery key}"
: "${HEADER_BACKUP_FILE:?HEADER_BACKUP_FILE must be copied to external escrow during the migration}"
: "${HEADER_ESCROW_ACK_FILE:?HEADER_ESCROW_ACK_FILE is required}"
: "${CONTAINER_SIZE_GB:?CONTAINER_SIZE_GB is required}"
: "${CONFIRM_NODE_ID:?CONFIRM_NODE_ID is required}"
[[ "$CONFIRM_NODE_ID" =~ ^node[0-9]+$ ]] || fail 'invalid CONFIRM_NODE_ID'
[[ "$CONTAINER_SIZE_GB" =~ ^[0-9]+$ ]] || fail 'CONTAINER_SIZE_GB must be an integer'
[ "$CONTAINER_SIZE_GB" -ge 100 ] || fail 'encrypted storage must be at least 100 GiB'
[ -f "$RECOVERY_KEY_FILE" ] && [ -r "$RECOVERY_KEY_FILE" ] || fail 'recovery key is unreadable'
[ "$(stat -c %a "$RECOVERY_KEY_FILE")" = 600 ] || fail 'recovery key must have mode 600'
[ "$(wc -c < "$RECOVERY_KEY_FILE")" -ge 32 ] || fail 'recovery key is too short'

ENV_FILE=/etc/ascii/baremetal-node-agent.env
if [ -f "$ENV_FILE" ]; then
  node_id="$(awk -F= '$1 == "BAREMETAL_NODE_ID" { print $2; exit }' "$ENV_FILE")"
else
  node_id="${NODE_ID:?NODE_ID is required when preparing a fresh node}"
  mkdir -p /var/lib/ascii /etc/ascii
fi
[ "$node_id" = "$CONFIRM_NODE_ID" ] || fail "confirmation does not match live node $node_id"

CONTAINER=/var/lib/ascii-storage.luks
MAPPER=ascii-node-storage
MOUNT=/var/lib/ascii
CREDENTIAL_MOUNT=/etc/ascii
STAGING_MOUNT=/mnt/ascii-node-storage-migration
STATE_ROOT=/var/lib/ascii-storage-migration
migration_id="$(date -u +%Y%m%dT%H%M%SZ)"
old_data="/var/lib/ascii.plaintext-$migration_id"
old_credentials="/etc/ascii.plaintext-$migration_id"
cutover=0
container_created=0
data_moved=0
credentials_moved=0
# ASC-286 rename: migrated nodes run ascii-node-manager.service (plus an update
# timer that would restart it mid-migration), unmigrated ones still run the
# legacy agent unit — operate on whichever is installed, and hold the timer.
node_unit=ascii-node-manager.service
systemctl cat "$node_unit" >/dev/null 2>&1 || node_unit=ascii-baremetal-node-agent.service
prior_agent="$(systemctl is-active "$node_unit" 2>/dev/null || true)"
prior_update_timer="$(systemctl is-active ascii-node-manager-update.timer 2>/dev/null || true)"
prior_reconcile="$(systemctl is-active ascii-baremetal-reconcile.service 2>/dev/null || true)"
running_file="$(mktemp)"

cleanup() {
  status=$?
  trap - EXIT
  if [ "$cutover" = 0 ]; then
    umount "$CREDENTIAL_MOUNT" 2>/dev/null || true
    umount "$MOUNT" 2>/dev/null || true
    umount "$STAGING_MOUNT" 2>/dev/null || true
    if [ "$credentials_moved" = 1 ]; then rmdir "$CREDENTIAL_MOUNT" 2>/dev/null || true; mv "$old_credentials" "$CREDENTIAL_MOUNT"; fi
    if [ "$data_moved" = 1 ]; then rmdir "$MOUNT" 2>/dev/null || true; mv "$old_data" "$MOUNT"; fi
    if [ -f "$STATE_ROOT/$migration_id/crypttab" ]; then cp -a "$STATE_ROOT/$migration_id/crypttab" /etc/crypttab; fi
    if [ -f "$STATE_ROOT/$migration_id/fstab" ]; then cp -a "$STATE_ROOT/$migration_id/fstab" /etc/fstab; fi
    systemctl daemon-reload 2>/dev/null || true
    cryptsetup close "$MAPPER" 2>/dev/null || true
    if command -v virsh >/dev/null; then
      while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        virsh domstate "$domain" 2>/dev/null | grep -q running || virsh start "$domain" >/dev/null 2>&1 || true
      done < "$running_file"
    fi
    if [ "$prior_reconcile" = active ]; then systemctl start ascii-baremetal-reconcile.service 2>/dev/null || true; fi
    if [ "$prior_agent" = active ]; then systemctl start "$node_unit" 2>/dev/null || true; fi
    if [ "$prior_update_timer" = active ]; then systemctl start ascii-node-manager-update.timer 2>/dev/null || true; fi
    if [ "$container_created" = 1 ]; then rm -f "$CONTAINER"; fi
  fi
  rm -f "$running_file" "$RECOVERY_KEY_FILE" "$HEADER_BACKUP_FILE" "$HEADER_ESCROW_ACK_FILE"
  exit "$status"
}
trap cleanup EXIT

findmnt -n "$MOUNT" >/dev/null 2>&1 && fail "$MOUNT is already a mount point"
findmnt -n "$CREDENTIAL_MOUNT" >/dev/null 2>&1 && fail "$CREDENTIAL_MOUNT is already a mount point"
[ ! -e "$CONTAINER" ] || fail "$CONTAINER already exists"
[ ! -e "/dev/mapper/$MAPPER" ] || fail "/dev/mapper/$MAPPER already exists"
[ -d "$MOUNT" ] && [ -d "$CREDENTIAL_MOUNT" ] || fail 'source directories are missing'
[[ "$RECOVERY_KEY_FILE" =~ ^/run/[A-Za-z0-9._-]+$ ]] || fail 'temporary recovery key must use a bounded /run path'
[[ "$HEADER_BACKUP_FILE" =~ ^/run/[A-Za-z0-9._-]+$ ]] || fail 'header backup must use a bounded /run path'
[[ "$HEADER_ESCROW_ACK_FILE" =~ ^/run/[A-Za-z0-9._-]+$ ]] || fail 'header escrow acknowledgment must use a bounded /run path'
[ ! -e "$HEADER_BACKUP_FILE" ] && [ ! -e "$HEADER_ESCROW_ACK_FILE" ] || fail 'header escrow paths already exist'
[ -c /dev/tpmrm0 ] || fail 'TPM2 resource manager is unavailable'

available_gb="$(df --output=avail -BG /var/lib | tail -1 | tr -dc '0-9')"
root_reserve_gb="${ROOT_RESERVE_GB:-50}"
[[ "$root_reserve_gb" =~ ^[0-9]+$ ]] && [ "$root_reserve_gb" -ge 50 ] || fail 'ROOT_RESERVE_GB must be at least 50'
[ "$CONTAINER_SIZE_GB" -le $((available_gb - root_reserve_gb)) ] \
  || fail "requested container leaves less than $root_reserve_gb GiB for the root filesystem"

log 'installing pinned-distribution encryption tools'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cryptsetup tpm2-tools rsync >/dev/null
systemd-cryptenroll --tpm2-device=list | grep -q /dev/tpmrm0 || fail 'systemd cannot use this TPM2 device'

log 'stopping admission and recording running domains'
systemctl stop ascii-node-manager-update.timer 2>/dev/null || true
systemctl stop "$node_unit" 2>/dev/null || true
systemctl stop ascii-baremetal-reconcile.service 2>/dev/null || true
# The move below happens underneath whatever is still running — a live manager
# here means silent corruption, so fail loudly instead.
! systemctl is-active --quiet "$node_unit" || fail 'node manager is still running after stop'
if command -v virsh >/dev/null; then
  virsh list --name | sed '/^$/d' > "$running_file"
  while IFS= read -r domain; do
    virsh shutdown "$domain" >/dev/null 2>&1 || true
  done < "$running_file"
  for _ in $(seq 1 30); do
    [ -z "$(virsh list --name | sed '/^$/d')" ] && break
    sleep 2
  done
  while IFS= read -r domain; do
    virsh domstate "$domain" 2>/dev/null | grep -q 'shut off' || virsh destroy "$domain" >/dev/null
  done < "$running_file"
fi

log "preallocating $CONTAINER_SIZE_GB GiB LUKS2 container"
fallocate -l "${CONTAINER_SIZE_GB}G" "$CONTAINER"
container_created=1
chmod 0600 "$CONTAINER"
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$RECOVERY_KEY_FILE" "$CONTAINER"
cryptsetup open --key-file "$RECOVERY_KEY_FILE" "$CONTAINER" "$MAPPER"
systemd-cryptenroll "$CONTAINER" --unlock-key-file="$RECOVERY_KEY_FILE" \
  --tpm2-device=auto --tpm2-pcrs= >/dev/null
cryptsetup close "$MAPPER"
systemd-cryptsetup attach "$MAPPER" "$CONTAINER" - 'tpm2-device=auto,headless' >/dev/null
cryptsetup status "$MAPPER" | grep -q 'is active' || fail 'TPM2 unlock verification failed'

mkfs.ext4 -q -L ascii-node-storage "/dev/mapper/$MAPPER"
mkdir -p "$STAGING_MOUNT"
mount -o noatime "/dev/mapper/$MAPPER" "$STAGING_MOUNT"
mkdir -p "$STAGING_MOUNT/node-credentials"
log 'copying VM data and node credentials while workloads are stopped'
rsync -aHAXS --numeric-ids "$MOUNT/" "$STAGING_MOUNT/"
rsync -aHAXS --numeric-ids "$CREDENTIAL_MOUNT/" "$STAGING_MOUNT/node-credentials/"
sync
data_diff="$(rsync -aHAXSni --delete --omit-dir-times --exclude=/node-credentials/ --exclude=/lost+found/ --numeric-ids "$MOUNT/" "$STAGING_MOUNT/")"
[ -z "$data_diff" ] || { printf '%s\n' "$data_diff" >&2; fail 'VM data changed during migration verification'; }
credential_diff="$(rsync -aHAXSni --delete --omit-dir-times --numeric-ids "$CREDENTIAL_MOUNT/" "$STAGING_MOUNT/node-credentials/")"
[ -z "$credential_diff" ] || { printf '%s\n' "$credential_diff" >&2; fail 'node credentials changed during migration verification'; }

mkdir -p "$STATE_ROOT/$migration_id"
cp -a /etc/crypttab /etc/fstab "$STATE_ROOT/$migration_id/"
cp "$running_file" "$STATE_ROOT/$migration_id/domains.running"
cryptsetup luksHeaderBackup "$CONTAINER" --header-backup-file "$HEADER_BACKUP_FILE"
chmod 0600 "$HEADER_BACKUP_FILE"
header_sha256="$(sha256sum "$HEADER_BACKUP_FILE" | awk '{print $1}')"
log "copy $HEADER_BACKUP_FILE to external escrow, verify SHA-256 $header_sha256, then write that digest to $HEADER_ESCROW_ACK_FILE"
escrowed=0
for _ in $(seq 1 180); do
  if [ -f "$HEADER_ESCROW_ACK_FILE" ] \
    && [ "$(tr -d '[:space:]' < "$HEADER_ESCROW_ACK_FILE")" = "$header_sha256" ]; then
    escrowed=1
    break
  fi
  sleep 10
done
[ "$escrowed" = 1 ] || fail 'external LUKS header escrow was not acknowledged'
cp "$HEADER_BACKUP_FILE" "$STAGING_MOUNT/luks-header-backup-$migration_id"
chmod 0600 "$STAGING_MOUNT/luks-header-backup-$migration_id"

log 'installing fail-closed boot mounts and cutting over'
crypttab_new="$(mktemp /etc/crypttab.ascii.XXXXXX)"
fstab_new="$(mktemp /etc/fstab.ascii.XXXXXX)"
cp /etc/crypttab "$crypttab_new"
cp /etc/fstab "$fstab_new"
grep -q '^ascii-node-storage[[:space:]]' "$crypttab_new" \
  || printf 'ascii-node-storage %s - tpm2-device=auto,headless\n' "$CONTAINER" >> "$crypttab_new"
{
  printf '\n# Ascii encrypted bare-metal storage (ASC-192)\n'
  printf '/dev/mapper/ascii-node-storage /var/lib/ascii ext4 noatime 0 2\n'
  printf '/var/lib/ascii/node-credentials /etc/ascii none bind 0 0\n'
} >> "$fstab_new"
install -m 0644 "$crypttab_new" /etc/crypttab
install -m 0644 "$fstab_new" /etc/fstab
rm -f "$crypttab_new" "$fstab_new"

umount "$STAGING_MOUNT"
mv "$MOUNT" "$old_data"
data_moved=1
mkdir -p "$MOUNT"
mv "$CREDENTIAL_MOUNT" "$old_credentials"
credentials_moved=1
mkdir -p "$CREDENTIAL_MOUNT"
mount "$MOUNT"
mount "$CREDENTIAL_MOUNT"

for target in "$MOUNT" "$CREDENTIAL_MOUNT"; do
  source="$(findmnt -n -o SOURCE -T "$target")"
  source="${source%%\[*}"
  lsblk -s -n -o TYPE "$source" | grep -qx crypt || fail "$target is not backed by dm-crypt after cutover"
done
cat > "$MOUNT/storage-encryption.json" <<EOF
{"version":1,"nodeId":"$node_id","migratedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","migrationBootId":"$(cat /proc/sys/kernel/random/boot_id)","container":"$CONTAINER","mapper":"$MAPPER","plaintextDataBackup":"$old_data","plaintextCredentialsBackup":"$old_credentials","unlock":"tpm2","pcrBinding":"none","headerSha256":"$header_sha256"}
EOF
chmod 0600 "$MOUNT/storage-encryption.json"

systemctl daemon-reload
if [ "$prior_reconcile" = active ]; then systemctl start ascii-baremetal-reconcile.service; fi
while IFS= read -r domain; do
  virsh domstate "$domain" 2>/dev/null | grep -q running || virsh start "$domain" >/dev/null
done < "$running_file"
if [ "$prior_agent" = active ]; then systemctl start "$node_unit"; fi
if [ "$prior_update_timer" = active ]; then systemctl start ascii-node-manager-update.timer; fi
cutover=1

log 'migration complete; verify recovery-key escrow and reboot before deleting plaintext backup paths'
log "plaintext backups retained: $old_data and $old_credentials"
