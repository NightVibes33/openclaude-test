#!/usr/bin/env bash
set -euo pipefail

# Rebuild volatile host networking after reboot from persistent libvirt domains
# plus non-sensitive machine metadata. Safe to run repeatedly.
VM_ROOT="${VM_ROOT:-/var/lib/ascii/vms}"
PUBLIC_INTERFACE="${PUBLIC_INTERFACE:?PUBLIC_INTERFACE is required}"
NODE_PUBLIC_IPV4="${NODE_PUBLIC_IPV4:?NODE_PUBLIC_IPV4 is required}"
NAT_NETWORK="${NAT_NETWORK:-default}"
QUARANTINE_MARKER="${QUARANTINE_MARKER:-/var/lib/ascii/baremetal/node-quarantined}"

log() { printf '[baremetal-reconcile] %s\n' "$*"; }
env_value() {
  local file="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

[ ! -e "$QUARANTINE_MARKER" ] \
  || { log "ERROR: node is persistently quarantined ($QUARANTINE_MARKER); operator cleanup is required"; exit 1; }

domain_output="$(virsh list --all --name)"
mapfile -t domains < <(printf '%s\n' "$domain_output" | grep -E '^box-[a-z0-9]+-[a-z0-9-]+$' | sort || true)
quarantined=0
quarantine_domain() {
  local domain="$1" reason="$2"
  log "ERROR: quarantining $domain: $reason"
  virsh autostart "$domain" --disable >/dev/null 2>&1 || true
  virsh destroy "$domain" >/dev/null 2>&1 || true
  # Remove it from authoritative inventory so ready pool rows cannot claim a
  # known-bad guest. Keep disk + machine-info ownership witnesses for the
  # backend's complete-inventory stale cleanup or an operator retry.
  virsh undefine "$domain" --nvram >/dev/null 2>&1 || virsh undefine "$domain" >/dev/null 2>&1 || true
  if virsh dominfo "$domain" >/dev/null 2>&1; then
    log "ERROR: quarantine could not remove $domain from authoritative inventory"
    return 1
  fi
  quarantined=$((quarantined + 1))
}
completed=0
quarantine_on_infrastructure_failure() {
  status=$?
  trap - EXIT
  if [ "$completed" != 1 ]; then
    log "ERROR: host reconciliation failed unexpectedly; stopping every domain to prevent split brain"
    for domain in "${domains[@]}"; do
      virsh destroy "$domain" >/dev/null 2>&1 || true
    done
  fi
  exit "$status"
}
trap quarantine_on_infrastructure_failure EXIT

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
sysctl -w "net.ipv6.conf.$PUBLIC_INTERFACE.proxy_ndp=1" >/dev/null
for name in "${domains[@]}"; do
  info="$VM_ROOT/$name/machine-info.env"
  if [ ! -f "$info" ]; then
    log "WARNING: $name has no machine-info.env; inventory remains visible but routes cannot be rebuilt"
    continue
  fi

  # Strip historical credentials and parse fixed keys strictly as data, never as shell code.
  tmp="$(mktemp "$VM_ROOT/$name/.machine-info.XXXXXX")"
  grep -Ev '^(SHARED_KEY|STREAMING_TOKEN|STREAMING_HOST_ID|STREAMING_APP_ID)=' "$info" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$info"
  MACHINE_IP="$(env_value "$info" MACHINE_IP)"
  NAT_IP="$(env_value "$info" NAT_IP)"
  VM_INDEX="$(env_value "$info" VM_INDEX)"

  if [ -n "${MACHINE_IP:-}" ]; then
    ip -6 neigh replace proxy "$MACHINE_IP" dev "$PUBLIC_INTERFACE"
  fi
  if [ -z "${NAT_IP:-}" ] || ! [[ "${VM_INDEX:-}" =~ ^[0-9]{1,3}$ ]] || [ "$VM_INDEX" -gt 255 ]; then
    quarantine_domain "$name" 'metadata has invalid NAT_IP/VM_INDEX'
    continue
  fi

  ssh_port=$((19000 + VM_INDEX))
  agent_port=$((21000 + VM_INDEX))
  webrtc_min=$((20000 + VM_INDEX * 8))
  webrtc_max=$((webrtc_min + 7))

  iptables -t nat -C PREROUTING -d "$NODE_PUBLIC_IPV4" -p tcp --dport "$ssh_port" \
    -m comment --comment "ascii:$name" -j DNAT --to-destination "$NAT_IP:22" 2>/dev/null \
    || iptables -t nat -A PREROUTING -d "$NODE_PUBLIC_IPV4" -p tcp --dport "$ssh_port" \
      -m comment --comment "ascii:$name" -j DNAT --to-destination "$NAT_IP:22"
  iptables -t nat -C PREROUTING -d "$NODE_PUBLIC_IPV4" -p tcp --dport "$agent_port" \
    -m comment --comment "ascii:$name" -j DNAT --to-destination "$NAT_IP:8911" 2>/dev/null \
    || iptables -t nat -A PREROUTING -d "$NODE_PUBLIC_IPV4" -p tcp --dport "$agent_port" \
      -m comment --comment "ascii:$name" -j DNAT --to-destination "$NAT_IP:8911"
  iptables -t nat -C PREROUTING -d "$NODE_PUBLIC_IPV4" -p udp --dport "$webrtc_min:$webrtc_max" \
    -m comment --comment "ascii:$name" -j DNAT --to-destination "$NAT_IP" 2>/dev/null \
    || iptables -t nat -A PREROUTING -d "$NODE_PUBLIC_IPV4" -p udp --dport "$webrtc_min:$webrtc_max" \
      -m comment --comment "ascii:$name" -j DNAT --to-destination "$NAT_IP"
  iptables -C FORWARD -d "$NAT_IP" -m conntrack --ctstate DNAT \
    -m comment --comment "ascii:$name" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -d "$NAT_IP" -m conntrack --ctstate DNAT \
      -m comment --comment "ascii:$name" -j ACCEPT

  virsh autostart "$name" >/dev/null
  if [ "$(virsh domstate "$name" 2>/dev/null || true)" != "running" ]; then
    virsh start "$name" >/dev/null
  fi
  log "reconciled $name"
done

# Do not expose the control plane until every persisted domain is customer-ready.
# A failed VM makes the node unavailable, causing the backend to quarantine its
# parked stock and recover assigned boxes elsewhere.
for name in "${domains[@]}"; do
  info="$VM_ROOT/$name/machine-info.env"
  if [ ! -f "$info" ]; then
    quarantine_domain "$name" 'metadata missing; node inventory is incomplete'
    continue
  fi
  MACHINE_IP="$(env_value "$info" MACHINE_IP)"
  if [ -z "${MACHINE_IP:-}" ]; then
    quarantine_domain "$name" 'MACHINE_IP is missing'
    continue
  fi
  [ "$(virsh domstate "$name" 2>/dev/null || true)" = running ] || continue
  ready=0
  for _ in $(seq 1 60); do
    if curl -g -fsS --max-time 5 "http://[$MACHINE_IP]:8911/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 10
  done
  if [ "$ready" != 1 ]; then
    quarantine_domain "$name" 'agent endpoint did not recover'
    continue
  fi
  log "endpoint proven: $name"
done

completed=1
log "complete: ${#domains[@]} discovered, $quarantined quarantined, all remaining endpoints healthy"
