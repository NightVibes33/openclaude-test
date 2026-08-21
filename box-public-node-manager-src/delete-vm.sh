#!/usr/bin/env bash
set -euo pipefail

# Removes a bare-metal VM created by provision-vm.sh.

NODE_ID="${NODE_ID:-node0}"
VM_ROOT="${VM_ROOT:-/var/lib/ascii/vms}"
STATE_DIR="${STATE_DIR:-/var/lib/ascii/baremetal}"
LEASE_DIR="$STATE_DIR/leases"
PUBLIC_INTERFACE="${PUBLIC_INTERFACE:-enp6s0}"
YES="${YES:-0}"

usage() {
  cat <<EOF
Usage: sudo ./bare-metal-node/delete-vm.sh VM_NAME [--yes]

Gateway cleanup is performed by the backend after ownership-validated host deletion.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

VM_NAME="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root, usually with sudo" >&2
  exit 1
fi

if [ "$YES" != "1" ]; then
  echo "Refusing to delete $VM_NAME without --yes" >&2
  exit 1
fi
[[ "$VM_NAME" =~ ^box-[a-z0-9]+-[a-z0-9-]+$ ]] || { echo "Invalid VM name" >&2; exit 1; }
env_value() {
  local file="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

VM_DIR="$VM_ROOT/$VM_NAME"
INFO_FILE="$VM_DIR/machine-info.env"

MACHINE_IP=""
VM_INDEX=""
MACHINE_SUBDOMAIN="$VM_NAME"
PUBLIC_FILTER=""
NAT_FILTER=""
if [ -f "$INFO_FILE" ]; then
  MACHINE_IP="$(env_value "$INFO_FILE" MACHINE_IP)"
  VM_INDEX="$(env_value "$INFO_FILE" VM_INDEX)"
  MACHINE_SUBDOMAIN="$(env_value "$INFO_FILE" MACHINE_SUBDOMAIN)"
  PUBLIC_FILTER="$(env_value "$INFO_FILE" PUBLIC_FILTER)"
  NAT_FILTER="$(env_value "$INFO_FILE" NAT_FILTER)"
  NAT_MAC="$(env_value "$INFO_FILE" NAT_MAC)"
  NAT_NETWORK="$(env_value "$INFO_FILE" NAT_NETWORK)"
  MACHINE_SUBDOMAIN="${MACHINE_SUBDOMAIN:-$VM_NAME}"
fi

if [ -z "$PUBLIC_FILTER" ] || [ -z "$NAT_FILTER" ]; then
  FILTER_DIGEST="$(printf '%s' "$VM_NAME" | sha256sum | cut -c1-10)"
  PUBLIC_FILTER="ascii-${FILTER_DIGEST}-public"
  NAT_FILTER="ascii-${FILTER_DIGEST}-nat"
fi

if [ -z "$VM_INDEX" ] && [ -d "$LEASE_DIR" ]; then
  LEASE_FILE="$(grep -l "^vm=$VM_NAME$" "$LEASE_DIR"/* 2>/dev/null | head -1 || true)"
  if [ -n "$LEASE_FILE" ]; then
    VM_INDEX="$(basename "$LEASE_FILE")"
    ipv6="$(env_value "$LEASE_FILE" ipv6)"
    MACHINE_IP="${MACHINE_IP:-${ipv6:-}}"
  fi
fi

echo "Destroying libvirt domain $VM_NAME"
virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || \
    virsh undefine "$VM_NAME" >/dev/null 2>&1 || {
      echo "Failed to undefine libvirt domain $VM_NAME" >&2
      exit 1
    }
fi
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "Refusing to erase ownership metadata: libvirt domain $VM_NAME still exists" >&2
  exit 1
fi
virsh nwfilter-undefine "$PUBLIC_FILTER" >/dev/null 2>&1 || true
virsh nwfilter-undefine "$NAT_FILTER" >/dev/null 2>&1 || true
for filter in "$PUBLIC_FILTER" "$NAT_FILTER"; do
  if virsh nwfilter-info "$filter" >/dev/null 2>&1; then
    echo "Failed to remove libvirt nwfilter $filter" >&2
    exit 1
  fi
done

if [ -n "$MACHINE_IP" ]; then
  echo "Removing proxy NDP $MACHINE_IP"
  ip -6 neigh del proxy "$MACHINE_IP" dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || true
fi

echo "Removing IPv4 doorway (DNAT rules + DHCP reservation)"
for table in nat filter; do
  # `|| true`: a VM with no doorway rules left (already-cleaned zombie) makes
  # grep exit 1, and under pipefail that killed the whole delete (ASC-294).
  iptables -t "$table" -S 2>/dev/null | { grep -F -- "ascii:$VM_NAME" || true; } | sed 's/^-[AI] */-D /' \
    | while IFS= read -r rule; do
        # eval: -S quotes the comment argument; plain word-splitting would
        # pass the quotes literally and the delete would not match.
        eval "iptables -t $table $rule" >/dev/null 2>&1 || true
      done
done
for table in nat filter; do
  rules="$(iptables -t "$table" -S)" || {
    echo "Failed to verify $table rules for $VM_NAME" >&2
    exit 1
  }
  if grep -F -- "ascii:$VM_NAME" <<< "$rules" >/dev/null; then
    echo "Failed to remove all $table rules for $VM_NAME" >&2
    exit 1
  fi
done
NAT_MAC="${NAT_MAC:-}"
if [ -z "$NAT_MAC" ] && [ -n "$VM_INDEX" ]; then
  NAT_MAC="52:54:00:aa:02:$(printf '%02x' "$VM_INDEX")"
fi
if [ -n "$NAT_MAC" ]; then
  virsh net-update "${NAT_NETWORK:-default}" delete ip-dhcp-host "<host mac='$NAT_MAC'/>" --live --config >/dev/null 2>&1 || true
  nat_network_xml="$(virsh net-dumpxml "${NAT_NETWORK:-default}")" || {
    echo "Failed to verify DHCP reservation removal for $NAT_MAC" >&2
    exit 1
  }
  if grep -F "$NAT_MAC" <<< "$nat_network_xml" >/dev/null; then
    echo "Failed to remove DHCP reservation for $NAT_MAC" >&2
    exit 1
  fi
fi

if [ -n "$VM_INDEX" ]; then
  rm -f "$LEASE_DIR/$VM_INDEX"
elif [ -d "$LEASE_DIR" ]; then
  while IFS= read -r lease_file; do
    rm -f "$lease_file"
  done < <(grep -l "^vm=$VM_NAME$" "$LEASE_DIR"/* 2>/dev/null || true)
fi

echo "Removing $VM_DIR"
rm -rf "$VM_DIR"

echo "Deleted $VM_NAME"
