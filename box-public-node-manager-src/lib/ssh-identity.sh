#!/usr/bin/env bash

# SSH host-identity pinning helpers (ASC-186). provision-vm.sh mints each
# guest's host key before first boot and seeds it via cloud-init; these
# helpers pin that key on every connection and classify verification
# failures so provisioning fails closed instead of talking to an impostor.

host_identity_known_hosts_write() {
  local out="$1" host="$2" pubkey_file="$3" port="${4:-22}"
  local key
  key="$(cut -d' ' -f1,2 < "$pubkey_file")"
  if [ "$port" = "22" ]; then
    printf '%s %s\n' "$host" "$key" > "$out"
  else
    printf '[%s]:%s %s\n' "$host" "$port" "$key" > "$out"
  fi
  chmod 644 "$out"
}

# Strict pinning: only the per-VM known_hosts entry counts, only the key type
# we minted is negotiated, and nothing may add or update entries.
host_identity_ssh_args() {
  local known_hosts="$1"
  printf '%s\n' \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$known_hosts" \
    -o GlobalKnownHostsFile=/dev/null \
    -o HostKeyAlgorithms=ssh-ed25519 \
    -o UpdateHostKeys=no
}

ssh_failure_is_identity_mismatch() {
  printf '%s' "$1" | grep -qiE \
    'host key verification failed|remote host identification has changed|no matching host key type'
}

# wait_for_verified_ssh <attempts> <delay_seconds> <mismatch_limit> <cmd...>
# Retries <cmd> until it succeeds. A guest that is still booting resets the
# mismatch counter; <mismatch_limit> consecutive identity failures mean
# something is answering with the wrong key, and waiting longer must never
# turn into talking to it. Returns 0 on success, 2 on identity mismatch,
# 1 on timeout.
wait_for_verified_ssh() {
  local attempts="$1" delay="$2" mismatch_limit="$3"
  shift 3
  local attempt err mismatches=0
  for attempt in $(seq 1 "$attempts"); do
    if err="$("$@" 2>&1)"; then
      return 0
    fi
    if ssh_failure_is_identity_mismatch "$err"; then
      mismatches=$((mismatches + 1))
      if [ "$mismatches" -eq 1 ]; then
        printf 'WARNING: peer presented an SSH host key that is not the one minted for this VM\n' >&2
      fi
      if [ "$mismatches" -ge "$mismatch_limit" ]; then
        printf 'host identity mismatch: %s\n' "$err" >&2
        return 2
      fi
    else
      mismatches=0
    fi
    sleep "$delay"
  done
  return 1
}
