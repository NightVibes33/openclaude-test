#!/usr/bin/env bash
# Restore tenant isolation after firewall/libvirt reloads and migrate existing
# harness domains. Safe to run at every node-agent start and before each create.
set -euo pipefail

fail() { echo "tenant isolation: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_ID="${NODE_ID:-node0}"
PUBLIC_NETWORK="${PUBLIC_NETWORK:-libvirt-$NODE_ID}"
NAT_NETWORK="${NAT_NETWORK:-default}"
VM_ROOT="${VM_ROOT:-/var/lib/ascii/vms}"
XML_HELPER="$SCRIPT_DIR/lib/isolate_domain_network.py"

for command in virsh iptables ip6tables bridge python3; do
  need_cmd "$command"
done
[ -f "$XML_HELPER" ] || fail "missing XML helper: $XML_HELPER"

network_bridge() {
  local network="$1"
  local bridge
  bridge="$(virsh net-info "$network" | awk '/^Bridge:/ { print $2; exit }')"
  [ -n "$bridge" ] || fail "cannot resolve bridge for $network"
  printf '%s\n' "$bridge"
}

install_forward_drop() {
  local command="$1"
  local bridge="$2"
  local comment="ascii:tenant-isolation:$bridge"

  while "$command" -C FORWARD -i "$bridge" -o "$bridge" \
    -m comment --comment "$comment" -j DROP >/dev/null 2>&1; do
    "$command" -D FORWARD -i "$bridge" -o "$bridge" \
      -m comment --comment "$comment" -j DROP
  done
  "$command" -I FORWARD 1 -i "$bridge" -o "$bridge" \
    -m comment --comment "$comment" -j DROP
}

public_bridge="$(network_bridge "$PUBLIC_NETWORK")"
nat_bridge="$(network_bridge "$NAT_NETWORK")"
install_forward_drop ip6tables "$public_bridge"
install_forward_drop iptables "$nat_bridge"

[ -d "$VM_ROOT" ] || exit 0
while IFS= read -r vm_dir; do
  name="$(basename "$vm_dir")"
  [[ "$name" =~ ^box-[a-z0-9]+-[a-z0-9-]+$ ]] || continue
  virsh dominfo "$name" >/dev/null 2>&1 || continue

  domain_xml="$(mktemp)"
  trap 'rm -f "${domain_xml:-}"' EXIT
  virsh dumpxml --inactive "$name" > "$domain_xml"
  python3 "$XML_HELPER" "$domain_xml" \
    --expected-network "$PUBLIC_NETWORK" \
    --expected-network "$NAT_NETWORK"
  virsh define "$domain_xml" >/dev/null
  rm -f "$domain_xml"
  trap - EXIT

  while IFS= read -r tap; do
    [ -e "/sys/class/net/$tap" ] || continue
    bridge link set dev "$tap" isolated on
  done < <(
    virsh domiflist "$name" | awk -v public="$PUBLIC_NETWORK" -v nat="$NAT_NETWORK" \
      'NR > 2 && ($3 == public || $3 == nat) { print $1 }'
  )
done < <(find "$VM_ROOT" -mindepth 1 -maxdepth 1 -type d -print)
