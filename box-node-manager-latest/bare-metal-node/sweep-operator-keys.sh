#!/usr/bin/env bash
set -euo pipefail

# One-shot ASC-187 remediation for guests provisioned BEFORE the
# ephemeral-key change. For every running VM on this node it removes all
# node-side public keys (operator keys that leaked via the old ~/.ssh
# fallback + the legacy shared provision key) from the guest's
# authorized_keys files, then disables guest root SSH and verifies the door
# is shut. Customer keys (installed by the agent-server under /home/user)
# are untouched: only keys the NODE knows about are stripped.
#
# Run on the node:  sudo ./sweep-operator-keys.sh [--dry-run]
#
# Parked (shut-off) VMs are skipped — re-run after they resume. Snapshots
# taken before the sweep still contain the old keys; a restored guest must
# be swept again.

VM_ROOT="${VM_ROOT:-/var/lib/ascii/vms}"
STATE_DIR="${STATE_DIR:-/var/lib/ascii/baremetal}"
LEGACY_KEY="${LEGACY_KEY:-$STATE_DIR/provision_ssh_key}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[sweep-operator-keys] %s\n' "$*"; }
fail() { printf '[sweep-operator-keys] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run as root on the bare-metal node"

# Reach each guest with the best available key: the per-VM provision key left
# behind when revocation was skipped (dev-mode nodes), else the legacy shared
# key for pre-ephemeral guests (ASC-186/187 lineage).
guest_key_for() {
  local vm_dir="$1"
  if [ -f "$vm_dir/provision-key" ]; then printf '%s\n' "$vm_dir/provision-key";
  elif [ -f "$LEGACY_KEY" ]; then printf '%s\n' "$LEGACY_KEY";
  else return 1; fi
}

guest_ssh() {
  local key="$1" ip="$2"
  shift 2
  ssh -6 -i "$key" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    "root@$ip" "$@"
}

# Every key blob this node trusts or could have leaked into guests: root's
# and all node users' authorized_keys/pubkeys (the old fallback read either,
# depending on SUDO_USER), plus the shared provision key. Blobs (the base64
# field) are matched instead of whole lines so comments/options don't matter.
BLOBS_FILE="$(mktemp)"
trap 'rm -f "$BLOBS_FILE" "$BLOBS_FILE.raw"' EXIT
# Tolerate missing/unmatched paths: a node without /home users or without
# *.pub files must not die here under pipefail (staging node1 2026-08-17).
for keyfile in /root/.ssh/authorized_keys /root/.ssh/*.pub \
  /home/*/.ssh/authorized_keys /home/*/.ssh/*.pub \
  "$LEGACY_KEY.pub"; do
  [ -f "$keyfile" ] || continue
  cat "$keyfile"
done > "$BLOBS_FILE.raw"
# Operator keys can also come from the node env (SSH_PUBLIC_KEYS or an
# authorized-keys file reference) — that is exactly the channel that leaked
# staging-machines into guests on node1. Include them in the strip set.
ENV_FILE="${BAREMETAL_NODE_AGENT_ENV_FILE:-/etc/ascii/baremetal-node-agent.env}"
if [ -f "$ENV_FILE" ]; then
  env_ssh_keys="$(sed -n 's/^SSH_PUBLIC_KEYS=//p' "$ENV_FILE" | tr -d '"' | tr ',' '\n')"
  [ -n "$env_ssh_keys" ] && printf '%s\n' "$env_ssh_keys" >> "$BLOBS_FILE.raw"
  env_keys_file="$(sed -n 's/^SSH_AUTHORIZED_KEYS_FILE=//p' "$ENV_FILE" | tr -d '"')"
  [ -n "$env_keys_file" ] && [ -f "$env_keys_file" ] && cat "$env_keys_file" >> "$BLOBS_FILE.raw"
fi
awk '{for (i = 1; i <= NF; i++) if ($i ~ /^AAAA/) { print $i; break }}' \
  < "$BLOBS_FILE.raw" | sort -u > "$BLOBS_FILE"
rm -f "$BLOBS_FILE.raw"
[ -s "$BLOBS_FILE" ] || fail "no node-side key blobs collected"
log "$(wc -l < "$BLOBS_FILE" | tr -d ' ') node-side key blob(s) to strip"

GUEST_SCRIPT='
set -eu
mode="$1"
blobs=/run/ascii-sweep.blobs
[ -s "$blobs" ] || { echo "NO_BLOBS"; exit 3; }
total=0
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -f "$f" ] || continue
  hits="$(grep -c -F -f "$blobs" "$f" || true)"
  [ "${hits:-0}" -gt 0 ] || continue
  total=$((total + hits))
  echo "MATCH $f $hits"
  if [ "$mode" = "apply" ]; then
    grep -v -F -f "$blobs" "$f" > "$f.tmp" || true
    cat "$f.tmp" > "$f"
    rm -f "$f.tmp"
  fi
done
if [ "$mode" = "apply" ]; then
  mkdir -p /etc/ssh/sshd_config.d
  printf "PermitRootLogin no\nPasswordAuthentication no\n" > /etc/ssh/sshd_config.d/00-ascii-lockdown.conf
  chmod 644 /etc/ssh/sshd_config.d/00-ascii-lockdown.conf
  systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true
fi
rm -f "$blobs"
echo "TOTAL $total"
'

mode="apply"
[ "$DRY_RUN" = "1" ] && mode="report"
overall_rc=0
seen=0

for info in "$VM_ROOT"/*/machine-info.env; do
  [ -f "$info" ] || continue
  seen=$((seen + 1))
  name="$(basename "$(dirname "$info")")"
  ip="$(sed -n 's/^MACHINE_IP=//p' "$info" | tail -1)"
  if [ -z "$ip" ]; then
    log "FAIL $name: no MACHINE_IP in machine-info.env"
    overall_rc=1
    continue
  fi
  if ! virsh domstate "$name" 2>/dev/null | grep -q running; then
    log "SKIP $name: not running (sweep again after it resumes)"
    continue
  fi

  log "sweeping $name ($ip) [$mode]"
  vm_key=""
  if ! vm_key="$(guest_key_for "$(dirname "$info")")"; then
    log "FAIL $name: no usable provision key (per-VM or legacy)"
    overall_rc=1
    continue
  fi
  # Strip the per-VM provision key as well as the fleet-wide blobs.
  vm_blobs="$(mktemp)"
  cat "$BLOBS_FILE" > "$vm_blobs"
  if [ -f "$(dirname "$info")/provision-key.pub" ]; then
    awk '{for (i = 1; i <= NF; i++) if ($i ~ /^AAAA/) { print $i; break }}' \
      "$(dirname "$info")/provision-key.pub" >> "$vm_blobs"
  fi
  if ! guest_ssh "$vm_key" "$ip" 'cat > /run/ascii-sweep.blobs && chmod 600 /run/ascii-sweep.blobs' < "$vm_blobs"; then
    rm -f "$vm_blobs"
    log "FAIL $name: cannot reach guest with any node-side provision key"
    overall_rc=1
    continue
  fi
  rm -f "$vm_blobs"
  if ! guest_ssh "$vm_key" "$ip" "bash -s -- $mode" <<< "$GUEST_SCRIPT"; then
    log "FAIL $name: guest sweep script failed"
    overall_rc=1
    continue
  fi

  if [ "$mode" = "apply" ]; then
    if guest_ssh "$vm_key" "$ip" true >/dev/null 2>&1; then
      log "FAIL $name: node-side key STILL accepted after sweep"
      overall_rc=1
    else
      log "OK $name: root SSH closed"
      # The key no longer opens anything; destroy the node-side copy too.
      rm -f "$(dirname "$info")/provision-key" "$(dirname "$info")/provision-key.pub"
    fi
  fi
done

[ "$seen" -gt 0 ] || log "no VMs found under $VM_ROOT"
if [ "$overall_rc" -eq 0 ]; then
  log "sweep complete"
  if [ "$DRY_RUN" = "0" ] && [ "$seen" -gt 0 ]; then
    log "NOTE: once all nodes are swept, delete the legacy shared key: rm -f $LEGACY_KEY $LEGACY_KEY.pub"
  fi
else
  log "sweep finished WITH FAILURES — see FAIL lines above"
fi
exit "$overall_rc"
