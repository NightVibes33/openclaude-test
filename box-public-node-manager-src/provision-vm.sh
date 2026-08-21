#!/usr/bin/env bash
set -euo pipefail

# Host-side VM provisioner. Runs on a bare-metal node (node0, node1, ...);
# per-node values (NODE_ID, IPV6_PREFIX, PUBLIC_INTERFACE) come from the
# node-agent's env file, defaults below encode node0. It creates a libvirt VM,
# runs guest setup, registers routes through a VM-scoped backend capability, and writes machine-info.env
# next to the VM disk. The node-agent exposes this proven sequence through the
# authenticated backend-only node API.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/vm-cpu.sh
source "$SCRIPT_DIR/lib/vm-cpu.sh"
# shellcheck source=lib/ssh-identity.sh
source "$SCRIPT_DIR/lib/ssh-identity.sh"
# shellcheck source=lib/vm-io.sh
source "$SCRIPT_DIR/lib/vm-io.sh"

NODE_ID="${NODE_ID:-node0}"
VM_PREFIX="${VM_PREFIX:-box-$NODE_ID}"
VM_NAME="${VM_NAME:-}"
VM_INDEX="${VM_INDEX:-}"
VM_IPV6="${VM_IPV6:-}"
OWNERSHIP_ID="${OWNERSHIP_ID:-}"
MACHINE_SUBDOMAIN="${MACHINE_SUBDOMAIN:-}"

BASE_IMAGE="${BASE_IMAGE:-}"
VM_ROOT="${VM_ROOT:-/var/lib/ascii/vms}"
STATE_DIR="${STATE_DIR:-/var/lib/ascii/baremetal}"
LEASE_DIR="$STATE_DIR/leases"

IPV6_PREFIX="${IPV6_PREFIX:-2001:41d0:1004:38a5:100}"
IPV6_PREFIX_LENGTH="${IPV6_PREFIX_LENGTH:-80}"
GUEST_IPV6_GATEWAY="${GUEST_IPV6_GATEWAY:-$IPV6_PREFIX::1}"
PUBLIC_INTERFACE="${PUBLIC_INTERFACE:-enp6s0}"
PUBLIC_NETWORK="${PUBLIC_NETWORK:-libvirt-$NODE_ID}"
NAT_NETWORK="${NAT_NETWORK:-default}"
ALLOCATE_START_INDEX="${ALLOCATE_START_INDEX:-32}"
ALLOCATE_END_INDEX="${ALLOCATE_END_INDEX:-239}"

VCPUS="${VCPUS:-4}"
VCPU_TOPOLOGY_SPEC=""
MEMORY_MB="${MEMORY_MB:-8192}"
DISK_SIZE="${DISK_SIZE:-70G}"
OS_VARIANT="${OS_VARIANT:-ubuntu24.04}"
CPU_SHARES="${CPU_SHARES:-1024}"

# IPv4 doorway (DNAT): guests are IPv6-only on the public side, so v4-only
# clients reach them through the node's public IPv4. Ports derive from
# VM_INDEX (unique per node, lowest-free-reused by the lease allocator):
#   ssh    tcp NODE_V4:(19000+index)            -> guest NAT v4 :22
#   webrtc udp NODE_V4:(20000+index*8, 8 ports) -> guest NAT v4 same ports
# The guest's NAT-bridge IPv4 is pinned to 192.168.122.<index> via a dnsmasq
# DHCP reservation so the DNAT target is stable. Rules are tagged
# "ascii:<vm-name>" for exact cleanup; they live in kernel memory only (VMs
# don't survive node reboots either).
NODE_PUBLIC_IPV4="${NODE_PUBLIC_IPV4:-}"
NAT_BRIDGE_V4_PREFIX="${NAT_BRIDGE_V4_PREFIX:-192.168.122}"
SSH_FWD_PORT_BASE="${SSH_FWD_PORT_BASE:-19000}"
WEBRTC_PORT_BASE="${WEBRTC_PORT_BASE:-20000}"
WEBRTC_PORTS_PER_VM="${WEBRTC_PORTS_PER_VM:-8}"
AGENT_FWD_PORT_BASE="${AGENT_FWD_PORT_BASE:-21000}"
AGENT_SERVER_PORT="${AGENT_SERVER_PORT:-8911}"

SSH_AUTHORIZED_KEYS_FILE="${SSH_AUTHORIZED_KEYS_FILE:-}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-}"
PROVISION_PUBLIC_KEY_FILE=""
REMOTE_SETUP_DIR="${REMOTE_SETUP_DIR:-/tmp/ascii-baremetal-setup}"

GUEST_RUNTIME_SCRIPT="$SCRIPT_DIR/guest-runtime-setup.sh"
NETWORK_ISOLATION_HELPER="$SCRIPT_DIR/lib/isolate_domain_network.py"
TENANT_ISOLATION_SCRIPT="$SCRIPT_DIR/ensure-tenant-isolation.sh"

AGENT_DOWNLOAD_URL="${AGENT_DOWNLOAD_URL:-}"
AGENT_SERVER_TAG="${AGENT_SERVER_TAG:-}"
AGENTS_SERVER_CHANNEL="${AGENTS_SERVER_CHANNEL:-}"
AGENT_PORT="${AGENT_PORT:-8911}"
BACKEND_URL="${BACKEND_URL:-https://ascii.dev}"
BOX_CLI_API_URL="${BOX_CLI_API_URL:-$BACKEND_URL}"
BOX_CLI_CHANNEL="${BOX_CLI_CHANNEL:-prod}"
BOX_CLI_MODE="${BOX_CLI_MODE:-box}"
BOX_CLI_TAG="${BOX_CLI_TAG:-}"
ENABLE_AGENT_V6_PROXY="${ENABLE_AGENT_V6_PROXY:-1}"

GATEWAY_PROXY_URL="${GATEWAY_PROXY_URL:-}"
GATEWAY_CAPABILITY="${GATEWAY_CAPABILITY:-}"
GATEWAY_EXPIRES="${GATEWAY_EXPIRES:-}"
GATEWAY_TARGET_IP=""
SKIP_CERT_GATEWAY="${SKIP_CERT_GATEWAY:-0}"
REGISTER_TEST_PORT="${REGISTER_TEST_PORT:-0}"
TEST_PORT="${TEST_PORT:-8081}"

SKIP_RUNTIME_SETUP="${SKIP_RUNTIME_SETUP:-0}"
CLEANUP_ON_FAILURE="${CLEANUP_ON_FAILURE:-1}"

LEASE_CREATED=0
VM_CREATED=0
EPHEMERAL_PROVISION_KEY=0
HOST_KEY_FILE=""
KNOWN_HOSTS_FILE=""
SSH_HOST_PUBKEY=""
VM_DIR=""
VM_DIR_CREATED=0
DOMAIN_NAME_OWNED=0
LEASE_FILE=""
PUBLIC_TAP=""
NAT_TAP=""
PUBLIC_FILTER=""
NAT_FILTER=""

usage() {
  cat <<EOF
Usage: sudo ./bare-metal-node/provision-vm.sh [options]

Options:
  --name NAME              VM name; default box-node0-<random>
  --index N                Allocation index; default first free from $ALLOCATE_START_INDEX..$ALLOCATE_END_INDEX
  --ipv6 ADDR              Explicit guest IPv6; index is derived from final hextet if --index is absent
  --subdomain NAME         cert-gateway subdomain; default VM name
  --skip-runtime-setup     Skip agent/desktop runtime setup
  --skip-cert-gateway      Skip cert-gateway route registration
  --cleanup-on-failure     Destroy VM and remove files if provisioning fails (default)
  -h, --help               Show this help

Important env vars:
  BASE_IMAGE               required exact checksummed qcow2 base-image path
  GATEWAY_PROXY_URL        backend proxy; requires VM-scoped capability fields
  AGENT_SERVER_TAG         exact release tag, e.g. agent-server-v0.0.49-ascii-prod29
  AGENTS_SERVER_CHANNEL    resolves latest channel tag when AGENT_SERVER_TAG is unset
  SSH_AUTHORIZED_KEYS_FILE dev only: standing guest root keys; skips the post-setup root SSH lockdown (never set for customer boxes)
  CLEANUP_ON_FAILURE      defaults to 1; set to 0 only to retain failed artifacts for debugging
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name) VM_NAME="$2"; shift 2 ;;
    --index) VM_INDEX="$2"; shift 2 ;;
    --ipv6) VM_IPV6="$2"; shift 2 ;;
    --subdomain) MACHINE_SUBDOMAIN="$2"; shift 2 ;;
    --skip-runtime-setup) SKIP_RUNTIME_SETUP=1; shift ;;
    --skip-cert-gateway) SKIP_CERT_GATEWAY=1; shift ;;
    --cleanup-on-failure) CLEANUP_ON_FAILURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

log() {
  printf '[baremetal-provision] %s\n' "$*"
}

phase() {
  local name="$1"
  shift
  local started elapsed
  started="$(date +%s%3N)"
  "$@"
  elapsed=$(( $(date +%s%3N) - started ))
  printf 'TIMING_MS:%s=%s\n' "$name" "$elapsed"
}

fail() {
  printf '[baremetal-provision] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

quote() {
  printf '%q' "$1"
}

cleanup_failure() {
  local rc=$? domain_gone route_name
  if [ "$rc" -eq 0 ]; then
    return
  fi

  printf '[baremetal-provision] failed with exit code %s\n' "$rc" >&2
  if [ "$CLEANUP_ON_FAILURE" = "1" ]; then
    log "cleanup-on-failure enabled; removing partial VM artifacts"
    domain_gone=1
    if [ "$DOMAIN_NAME_OWNED" = 1 ]; then
      virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
      virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
      if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        domain_gone=0
        log "ERROR: partial domain still exists; preserving its ownership metadata and host state"
      else
        cleanup_vm_filters
      fi
    fi
    if [ "$domain_gone" = 1 ]; then
      if [ -n "$VM_IPV6" ]; then
        ip -6 neigh del proxy "$VM_IPV6" dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || true
      fi
      remove_ipv4_doorway
      if [ -n "$VM_NAME" ] && [ -n "$GATEWAY_PROXY_URL" ] && [ -n "$GATEWAY_CAPABILITY" ]; then
        for route_name in "$VM_NAME" "$VM_NAME-desktop" "$VM_NAME-$TEST_PORT"; do
          gateway_request unregister-route "$(jq -nc --arg machineName "$route_name" '{machineName: $machineName}')" >/dev/null 2>&1 || true
        done
        gateway_request unregister-wireguard "$(jq -nc --arg machineName "$VM_NAME" '{machineName: $machineName}')" >/dev/null 2>&1 || true
      fi
      if [ "$VM_DIR_CREATED" = 1 ] && [ -n "$VM_DIR" ] && [ -d "$VM_DIR" ]; then
        rm -rf "$VM_DIR"
      fi
      if [ "$LEASE_CREATED" = "1" ] && [ -n "$LEASE_FILE" ]; then
        rm -f "$LEASE_FILE"
      fi
    fi
  else
    if [ "$LEASE_CREATED" = "1" ] && [ "$VM_CREATED" != "1" ] && [ -n "$LEASE_FILE" ]; then
      rm -f "$LEASE_FILE"
    fi
    log "left partial artifacts for debugging; rerun delete-vm.sh to remove them"
  fi
}
trap cleanup_failure EXIT

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "run this on the bare-metal node as root, usually with sudo"
  fi
}

find_base_image() {
  [ -n "$BASE_IMAGE" ] || fail "BASE_IMAGE must pin a promoted image; newest-image fallback is forbidden"
  [ -f "$BASE_IMAGE" ] || fail "BASE_IMAGE does not exist: $BASE_IMAGE"
  [ -f "$BASE_IMAGE.sha256" ] || fail "BASE_IMAGE checksum is missing: $BASE_IMAGE.sha256"
  local expected actual
  expected="$(awk '{print $1}' "$BASE_IMAGE.sha256")"
  actual="$(sha256sum "$BASE_IMAGE" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || fail "BASE_IMAGE checksum mismatch: $BASE_IMAGE"
}

random_suffix() {
  openssl rand -hex 3
}

derive_index_from_ipv6() {
  local last_hextet="${VM_IPV6##*:}"
  if [ -z "$last_hextet" ]; then
    fail "cannot derive VM_INDEX from VM_IPV6=$VM_IPV6; pass --index"
  fi
  VM_INDEX="$((16#$last_hextet))"
}

validate_requested_network() {
  [ -n "$VM_IPV6" ] || return 0
  python3 - "$VM_IPV6" "$IPV6_PREFIX" "$IPV6_PREFIX_LENGTH" "$VM_INDEX" <<'PY'
import ipaddress
import sys

address = ipaddress.IPv6Address(sys.argv[1])
prefix = sys.argv[2].rstrip(':') + '::'
network = ipaddress.IPv6Network(f'{prefix}/{sys.argv[3]}', strict=False)
if address not in network:
    raise SystemExit(f'IPv6 address {address} is outside {network}')
if sys.argv[4] and int(sys.argv[4]) != int(address.exploded.split(':')[-1], 16):
    raise SystemExit('VM_INDEX does not match the IPv6 final hextet')
PY
}

allocate_ip() {
  mkdir -p "$LEASE_DIR"
  # Serialize only the lease scan/write. Provisioning remains concurrent, but
  # two creates can never inspect the same free slot and make one fail spuriously.
  exec 8>"$LEASE_DIR/.allocation.lock"
  flock 8

  if [ -z "$VM_NAME" ]; then
    VM_NAME="$VM_PREFIX-$(random_suffix)"
  fi

  if [ -n "$VM_IPV6" ] && [ -z "$VM_INDEX" ]; then
    derive_index_from_ipv6
  fi

  if [ -n "$VM_INDEX" ]; then
    if ! [[ "$VM_INDEX" =~ ^[0-9]+$ ]]; then
      fail "VM_INDEX must be numeric: $VM_INDEX"
    fi
    if [ -z "$VM_IPV6" ]; then
      VM_IPV6="$IPV6_PREFIX::$(printf '%x' "$VM_INDEX")"
    fi
  else
    local idx hex candidate lease
    for idx in $(seq "$ALLOCATE_START_INDEX" "$ALLOCATE_END_INDEX"); do
      hex="$(printf '%x' "$idx")"
      candidate="$IPV6_PREFIX::$hex"
      lease="$LEASE_DIR/$idx"
      [ -e "$lease" ] && continue
      if ip -6 neigh show proxy | grep -Fq "$candidate "; then
        continue
      fi
      VM_INDEX="$idx"
      VM_IPV6="$candidate"
      break
    done
    [ -n "$VM_INDEX" ] || fail "no free IPv6 allocation index in $ALLOCATE_START_INDEX..$ALLOCATE_END_INDEX"
  fi

  if [ "$VM_INDEX" -lt 2 ] || [ "$VM_INDEX" -gt 239 ]; then
    fail "VM_INDEX must be in 2..239 for current MAC generation: $VM_INDEX"
  fi

  LEASE_FILE="$LEASE_DIR/$VM_INDEX"
  if [ -e "$LEASE_FILE" ]; then
    fail "allocation index already leased: $VM_INDEX ($LEASE_FILE)"
  fi

  if ! (set -o noclobber; printf 'vm=%s\nipv6=%s\ncreated_at=%s\n' "$VM_NAME" "$VM_IPV6" "$(date -Is)" > "$LEASE_FILE") 2>/dev/null; then
    fail "failed to claim lease: $LEASE_FILE"
  fi
  LEASE_CREATED=1
  flock -u 8

  MACHINE_SUBDOMAIN="${MACHINE_SUBDOMAIN:-$VM_NAME}"
}

# Linux interface names are limited to 15 bytes. A deterministic digest keeps
# tap/filter identity stable across libvirt and harness restarts without putting
# the potentially long VM name into a kernel identifier.
derive_network_names() {
  local digest
  digest="$(printf '%s' "$VM_NAME" | sha256sum | cut -c1-10)"
  PUBLIC_TAP="ap${digest}p"
  NAT_TAP="ap${digest}n"
  PUBLIC_FILTER="ascii-${digest}-public"
  NAT_FILTER="ascii-${digest}-nat"
}

define_vm_filters() {
  local public_xml nat_xml
  public_xml="$(mktemp)"
  nat_xml="$(mktemp)"

  # Public NIC: its known MAC and assigned public IPv6 are the only permitted
  # guest identities. NDP/ICMPv6 and ordinary IPv6 remain fully functional.
  cat > "$public_xml" <<EOF
<filter name='$PUBLIC_FILTER' chain='root'>
  <filterref filter='no-mac-spoofing'/>
  <filterref filter='no-ipv6-spoofing'>
    <parameter name='IPV6' value='$VM_IPV6'/>
  </filterref>
  <rule action='accept' direction='inout' priority='-500'>
    <mac protocolid='ipv6'/>
  </rule>
  <filterref filter='qemu-announce-self'/>
  <filterref filter='no-other-l2-traffic'/>
</filter>
EOF

  # NAT NIC: clean-traffic enforces MAC, ARP and the DHCP-reserved IPv4. Its
  # stock no-ip-spoofing filter explicitly allows 0.0.0.0 DHCP requests.
  cat > "$nat_xml" <<EOF
<filter name='$NAT_FILTER' chain='root'>
  <filterref filter='clean-traffic'>
    <parameter name='IP' value='$NAT_IP'/>
  </filterref>
</filter>
EOF
  if ! virsh nwfilter-define "$public_xml" >/dev/null; then
    rm -f "$public_xml" "$nat_xml"
    fail "failed to define public nwfilter $PUBLIC_FILTER"
  fi
  if ! virsh nwfilter-define "$nat_xml" >/dev/null; then
    virsh nwfilter-undefine "$PUBLIC_FILTER" >/dev/null 2>&1 || true
    rm -f "$public_xml" "$nat_xml"
    fail "failed to define NAT nwfilter $NAT_FILTER"
  fi
  rm -f "$public_xml" "$nat_xml"
}

cleanup_vm_filters() {
  [ -n "$PUBLIC_FILTER" ] && virsh nwfilter-undefine "$PUBLIC_FILTER" >/dev/null 2>&1 || true
  [ -n "$NAT_FILTER" ] && virsh nwfilter-undefine "$NAT_FILTER" >/dev/null 2>&1 || true
}

validate_names() {
  [[ "$VM_NAME" =~ ^box-[a-z0-9]+-[a-z0-9-]+$ ]] || fail "VM_NAME must look like box-node0-abc123: $VM_NAME"
  [[ "$OWNERSHIP_ID" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || fail "OWNERSHIP_ID is required and invalid"
  [[ "$MACHINE_SUBDOMAIN" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid subdomain: $MACHINE_SUBDOMAIN"
}

write_ownership_witness() {
  local tmp="$VM_DIR/.machine-info.provisional"
  {
    printf 'PROVIDER=baremetal\n'
    printf 'NODE_ID=%q\n' "$NODE_ID"
    printf 'MACHINE_NAME=%q\n' "$VM_NAME"
    printf 'MACHINE_ID=%q\n' "$VM_NAME"
    printf 'OWNERSHIP_ID=%q\n' "$OWNERSHIP_ID"
    printf 'MACHINE_IP=%q\n' "$VM_IPV6"
    printf 'MACHINE_IP_TYPE=IPv6\n'
    printf 'MACHINE_SUBDOMAIN=%q\n' "$MACHINE_SUBDOMAIN"
    printf 'VM_INDEX=%q\n' "$VM_INDEX"
    printf 'PUBLIC_MAC=%q\n' "$PUBLIC_MAC"
    printf 'NAT_MAC=%q\n' "$NAT_MAC"
    printf 'NAT_IP=%q\n' "$NAT_IP"
    printf 'PUBLIC_FILTER=%q\n' "$PUBLIC_FILTER"
    printf 'NAT_FILTER=%q\n' "$NAT_FILTER"
    printf 'NAT_NETWORK=%q\n' "$NAT_NETWORK"
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$VM_DIR/machine-info.env"
}

resolve_ssh_keys() {
  local out="$VM_DIR/authorized_keys"
  : > "$out"

  # Explicit sources only, for dev/debug. There is deliberately NO fallback to
  # the invoking user's ~/.ssh: the node-agent runs as root, and the node's
  # /root/.ssh/authorized_keys must never leak into customer guests (ASC-187).
  if [ -n "${SSH_PUBLIC_KEYS:-}" ]; then
    printf '%s\n' "$SSH_PUBLIC_KEYS" >> "$out"
  elif [ -n "$SSH_AUTHORIZED_KEYS_FILE" ]; then
    [ -f "$SSH_AUTHORIZED_KEYS_FILE" ] || fail "SSH_AUTHORIZED_KEYS_FILE not found: $SSH_AUTHORIZED_KEYS_FILE"
    cat "$SSH_AUTHORIZED_KEYS_FILE" >> "$out"
  fi

  cat "$PROVISION_PUBLIC_KEY_FILE" >> "$out"

  grep -E '^(ssh-|ecdsa-|sk-)' "$out" | sort -u > "$out.filtered" || fail "no public SSH keys found"
  mv "$out.filtered" "$out"
}

ensure_provision_ssh_key() {
  # Fresh throwaway keypair per VM (ASC-187): it exists only for the setup
  # window and revoke_provision_access removes it from the guest and the node.
  # An explicit SSH_PRIVATE_KEY_FILE is a dev override and is left in place.
  if [ -z "$SSH_PRIVATE_KEY_FILE" ]; then
    SSH_PRIVATE_KEY_FILE="$VM_DIR/provision-key"
    ssh-keygen -t ed25519 -N '' -f "$SSH_PRIVATE_KEY_FILE" -C "ascii-provision-$VM_NAME" >/dev/null
    EPHEMERAL_PROVISION_KEY=1
  fi

  chmod 600 "$SSH_PRIVATE_KEY_FILE"
  if [ ! -f "$SSH_PRIVATE_KEY_FILE.pub" ]; then
    ssh-keygen -y -f "$SSH_PRIVATE_KEY_FILE" > "$SSH_PRIVATE_KEY_FILE.pub"
  fi
  chmod 644 "$SSH_PRIVATE_KEY_FILE.pub"
  PROVISION_PUBLIC_KEY_FILE="$SSH_PRIVATE_KEY_FILE.pub"
}

# ASC-186: the guest's SSH host identity is minted here, before first boot,
# seeded into the guest via cloud-init, and pinned on every connection this
# script makes. The setup channel runs as root and carries Box credentials
# back, so it must never reach an sshd we cannot prove is the VM we created.
ensure_vm_host_identity() {
  HOST_KEY_FILE="$VM_DIR/host-key"
  ssh-keygen -t ed25519 -N '' -f "$HOST_KEY_FILE" -C "$VM_NAME" >/dev/null
  SSH_HOST_PUBKEY="$(cut -d' ' -f1,2 < "$HOST_KEY_FILE.pub")"
  KNOWN_HOSTS_FILE="$VM_DIR/known_hosts"
  host_identity_known_hosts_write "$KNOWN_HOSTS_FILE" "$VM_IPV6" "$HOST_KEY_FILE.pub"
}

write_cloud_init() {
  local mac_byte public_mac nat_mac
  mac_byte="$(printf '%02x' "$VM_INDEX")"
  public_mac="${PUBLIC_MAC:-52:54:00:aa:01:$mac_byte}"
  nat_mac="${NAT_MAC:-52:54:00:aa:02:$mac_byte}"

  resolve_ssh_keys

  {
    printf 'instance-id: %s\n' "$VM_NAME"
    printf 'local-hostname: %s\n' "$VM_NAME"
  } > "$VM_DIR/meta-data"

  # Keys go to root ONLY, and only for the provisioning window: the list is
  # the per-VM throwaway key (plus explicit dev keys, if any), and
  # revoke_provision_access strips it and sets PermitRootLogin no before the
  # box is handed over (ASC-187). The default user gets NO keys here —
  # customer keys are installed later by the agent-server. The runcmd guard
  # clears a lockdown inherited from a snapshot-derived disk so a future
  # re-provision flow can't lock itself out; it runs once per instance, so
  # restarting a parked VM keeps its lockdown.
  {
    printf '#cloud-config\n'
    printf 'hostname: %s\n' "$VM_NAME"
    printf 'manage_etc_hosts: true\n'
    printf 'disable_root: false\n'
    printf 'ssh_pwauth: false\n'
    printf 'users:\n'
    printf '  - default\n'
    printf '  - name: root\n'
    printf '    lock_passwd: true\n'
    printf '    ssh_authorized_keys:\n'
    while IFS= read -r key; do
      printf '      - %s\n' "$key"
    done < "$VM_DIR/authorized_keys"
    printf 'runcmd:\n'
    printf '  - rm -f /etc/ssh/sshd_config.d/00-ascii-lockdown.conf\n'
    printf '  - systemctl reload-or-restart ssh || systemctl reload-or-restart sshd || true\n'
    # The minted host identity (ASC-186): cloud-init writes this pair to
    # /etc/ssh and skips generating any other host keys, so the first sshd
    # to answer on the guest IP with this key is provably our VM. The base
    # image ships no host keys (base-image-qemu.pkr.hcl strips them) and
    # ssh_deletekeys clears any that a snapshot-derived disk carries over.
    printf 'ssh_deletekeys: true\n'
    printf 'ssh_keys:\n'
    printf '  ed25519_private: |\n'
    sed 's/^/    /' "$HOST_KEY_FILE"
    printf '  ed25519_public: %s\n' "$(cat "$HOST_KEY_FILE.pub")"
    printf 'package_update: false\n'
  } > "$VM_DIR/user-data"
  chmod 600 "$VM_DIR/user-data"

  cat > "$VM_DIR/network-config" <<EOF
version: 2
ethernets:
  public0:
    match:
      macaddress: "$public_mac"
    set-name: ens3
    dhcp4: false
    dhcp6: false
    addresses:
      - $VM_IPV6/$IPV6_PREFIX_LENGTH
    routes:
      - to: default
        via: $GUEST_IPV6_GATEWAY
    nameservers:
      addresses:
        - 2606:4700:4700::1111
        - 2001:4860:4860::8888
  nat0:
    match:
      macaddress: "$nat_mac"
    set-name: enp7s0
    dhcp4: true
    dhcp6: false
EOF

  cloud-localds --network-config="$VM_DIR/network-config" "$VM_DIR/seed.iso" "$VM_DIR/user-data" "$VM_DIR/meta-data"
  # The seed carries the guest's host private key; qemu reads it as owner
  # (create_vm chowns it to libvirt-qemu), so no world-readable bit needed.
  chmod 640 "$VM_DIR/seed.iso"
  # No loose copy of the guest's private identity on the node beyond the seed.
  rm -f "$HOST_KEY_FILE"

  PUBLIC_MAC="$public_mac"
  NAT_MAC="$nat_mac"
}

resolve_node_public_ipv4() {
  if [ -z "$NODE_PUBLIC_IPV4" ]; then
    NODE_PUBLIC_IPV4="$(ip -o -4 addr show "$PUBLIC_INTERFACE" | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
  fi
  [ -n "$NODE_PUBLIC_IPV4" ] || fail "cannot detect NODE_PUBLIC_IPV4 on $PUBLIC_INTERFACE"
  NAT_IP="$NAT_BRIDGE_V4_PREFIX.$VM_INDEX"
  SSH_FWD_PORT=$((SSH_FWD_PORT_BASE + VM_INDEX))
  WEBRTC_PORT_MIN=$((WEBRTC_PORT_BASE + VM_INDEX * WEBRTC_PORTS_PER_VM))
  WEBRTC_PORT_MAX=$((WEBRTC_PORT_MIN + WEBRTC_PORTS_PER_VM - 1))
  SSH_ENDPOINT="$NODE_PUBLIC_IPV4:$SSH_FWD_PORT"
  AGENT_FWD_PORT=$((AGENT_FWD_PORT_BASE + VM_INDEX))
  AGENT_ENDPOINT="$NODE_PUBLIC_IPV4:$AGENT_FWD_PORT"
}

# iptables (nft backend) instead of raw nft: ufw and libvirt already manage
# this hook universe through iptables chains, and a DNATed flow must survive
# ALL of them (ufw's FORWARD drop policy, libvirt's virbr0 reject). Speaking
# the same dialect lets us insert the accept at the head of FORWARD.
setup_ipv4_doorway() {
  need_cmd nft
  need_cmd iptables
  need_cmd ip6tables

  log "pinning guest NAT IPv4 $NAT_IP (dnsmasq reservation for $NAT_MAC)"
  virsh net-update "$NAT_NETWORK" delete ip-dhcp-host "<host mac='$NAT_MAC'/>" --live --config >/dev/null 2>&1 || true
  virsh net-update "$NAT_NETWORK" add-last ip-dhcp-host "<host mac='$NAT_MAC' ip='$NAT_IP'/>" --live --config >/dev/null

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  log "adding IPv4 doorway: ssh $SSH_ENDPOINT, agent $AGENT_ENDPOINT, webrtc udp $WEBRTC_PORT_MIN-$WEBRTC_PORT_MAX"
  iptables -t nat -A PREROUTING -d "$NODE_PUBLIC_IPV4" -p tcp --dport "$SSH_FWD_PORT" \
    -m comment --comment "ascii:$VM_NAME" -j DNAT --to-destination "$NAT_IP:22"
  # Agent-server doorway: the backend's direct machine RPC (health loop, restore
  # verification) targets ip:8911; v4-only backends reach it through this port.
  iptables -t nat -A PREROUTING -d "$NODE_PUBLIC_IPV4" -p tcp --dport "$AGENT_FWD_PORT" \
    -m comment --comment "ascii:$VM_NAME" -j DNAT --to-destination "$NAT_IP:$AGENT_SERVER_PORT"
  iptables -t nat -A PREROUTING -d "$NODE_PUBLIC_IPV4" -p udp --dport "$WEBRTC_PORT_MIN:$WEBRTC_PORT_MAX" \
    -m comment --comment "ascii:$VM_NAME" -j DNAT --to-destination "$NAT_IP"
  # Only traffic entering from the node's public NIC may use the doorway. This
  # prevents a guest from hairpinning through the node IPv4 to reach a peer.
  iptables -I FORWARD 1 -i "$PUBLIC_INTERFACE" -d "$NAT_IP" \
    -m conntrack --ctstate DNAT -m comment --comment "ascii:$VM_NAME" -j ACCEPT

  # Install these last so they stay ahead of libvirt's same-bridge ACCEPT and
  # all per-VM DNAT accepts. The node-agent runs the same repair at startup.
  "$TENANT_ISOLATION_SCRIPT"
}

remove_ipv4_doorway() {
  local table
  for table in nat filter; do
    # `|| true`: no matching rules means grep exits 1, and under pipefail that
    # would abort cleanup and leak the half-provisioned VM (ASC-294).
    iptables -t "$table" -S 2>/dev/null | { grep -F -- "ascii:$VM_NAME" || true; } | sed 's/^-[AI] */-D /' \
      | while IFS= read -r rule; do
          # eval: -S quotes the comment argument; plain word-splitting would
          # pass the quotes literally and the delete would not match.
          eval "iptables -t $table $rule" >/dev/null 2>&1 || true
        done
  done
  if [ -n "${NAT_MAC:-}" ]; then
    virsh net-update "$NAT_NETWORK" delete ip-dhcp-host "<host mac='$NAT_MAC'/>" --live --config >/dev/null 2>&1 || true
  fi
}

ensure_libvirt() {
  virsh net-info "$PUBLIC_NETWORK" >/dev/null 2>&1 || fail "libvirt network missing: $PUBLIC_NETWORK"
  if [ "$(virsh net-info "$PUBLIC_NETWORK" | awk '/^Active:/ { print $2; exit }')" != "yes" ]; then
    virsh net-start "$PUBLIC_NETWORK"
  fi

  virsh net-info "$NAT_NETWORK" >/dev/null 2>&1 || fail "libvirt NAT network missing: $NAT_NETWORK"
  if [ "$(virsh net-info "$NAT_NETWORK" | awk '/^Active:/ { print $2; exit }')" != "yes" ]; then
    virsh net-start "$NAT_NETWORK"
  fi

  if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    fail "libvirt domain already exists: $VM_NAME"
  fi
}

create_vm() {
  [ ! -e "$VM_DIR/root.qcow2" ] || fail "VM disk already exists: $VM_DIR/root.qcow2"

  log "creating qcow2 overlay from $BASE_IMAGE"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_DIR/root.qcow2" "$DISK_SIZE"
  chmod 644 "$VM_DIR/root.qcow2"
  if id -u libvirt-qemu >/dev/null 2>&1; then
    chown libvirt-qemu:kvm "$VM_DIR/root.qcow2" "$VM_DIR/seed.iso"
  fi

  log "adding proxy NDP for $VM_IPV6 on $PUBLIC_INTERFACE"
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
  sysctl -w "net.ipv6.conf.$PUBLIC_INTERFACE.proxy_ndp=1" >/dev/null
  ip -6 neigh replace proxy "$VM_IPV6" dev "$PUBLIC_INTERFACE"

  local domain_xml="$VM_DIR/domain.xml"

  log "rendering isolated domain XML for $VM_NAME"
  define_vm_filters
  virt-install \
    --import \
    --name "$VM_NAME" \
    --memory "$MEMORY_MB" \
    --vcpus "$VCPU_TOPOLOGY_SPEC" \
    --cpu host-passthrough \
    --disk "path=$VM_DIR/root.qcow2,format=qcow2,bus=virtio,discard=unmap" \
    --disk "path=$VM_DIR/seed.iso,device=cdrom" \
    --os-variant "$OS_VARIANT" \
    --network "network=$PUBLIC_NETWORK,model=virtio,mac=$PUBLIC_MAC,target.dev=$PUBLIC_TAP,filterref.filter=$PUBLIC_FILTER" \
    --network "network=$NAT_NETWORK,model=virtio,mac=$NAT_MAC,target.dev=$NAT_TAP,filterref.filter=$NAT_FILTER" \
    --graphics none \
    --noautoconsole \
    --print-xml \
    --dry-run > "$domain_xml"

  python3 "$NETWORK_ISOLATION_HELPER" "$domain_xml" \
    --expected-network "$PUBLIC_NETWORK" \
    --expected-network "$NAT_NETWORK"

  log "defining and starting $VM_NAME"
  virsh define "$domain_xml" >/dev/null
  VM_CREATED=1
  virsh start "$VM_NAME" >/dev/null

  # Do not impose an absolute disk ceiling on an otherwise idle guest. Apply
  # explicit zeros live and persistently so inherited limits cannot survive.
  virsh schedinfo "$VM_NAME" --set "cpu_shares=$CPU_SHARES" --live --config >/dev/null
  vm_io_apply_policy "$VM_NAME" vda --live --config >/dev/null
  virsh autostart "$VM_NAME" >/dev/null
}

ssh_base_args() {
  local args=(
    -6
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=8
  )
  # ASC-186: every connection is checked against the host key minted at
  # creation; an unknown or changed identity refuses to connect.
  local pin=()
  mapfile -t pin < <(host_identity_ssh_args "$KNOWN_HOSTS_FILE")
  args+=("${pin[@]}")
  if [ -n "$SSH_PRIVATE_KEY_FILE" ]; then
    args=(-i "$SSH_PRIVATE_KEY_FILE" "${args[@]}")
  fi
  printf '%s\n' "${args[@]}"
}

ssh_root() {
  local args=()
  mapfile -t args < <(ssh_base_args)
  ssh "${args[@]}" "root@$VM_IPV6" "$@"
}

scp_to_guest() {
  local source="$1"
  local destination="$2"
  local args=()
  mapfile -t args < <(ssh_base_args)
  scp "${args[@]}" -r "$source" "root@[$VM_IPV6]:$destination"
}

wait_for_ssh() {
  log "waiting for SSH on $VM_IPV6 (host identity pinned)"
  local rc=0
  wait_for_verified_ssh 600 2 15 ssh_root "true" || rc=$?
  case "$rc" in
    0) log "SSH ready, host identity verified" ;;
    2) fail "SSH host identity mismatch on $VM_IPV6: whatever is answering is not the VM we created; refusing to provision" ;;
    *) fail "guest did not become SSH-ready within 20 minutes" ;;
  esac
}

# The base image is a golden qcow2 with all dependencies and product binaries
# baked in (base-image-qemu.pkr.hcl); the guest only needs per-VM runtime setup.
copy_guest_inputs() {
  log "copying guest setup inputs"
  ssh_root "rm -rf $(quote "$REMOTE_SETUP_DIR") && mkdir -p $(quote "$REMOTE_SETUP_DIR")"
  scp_to_guest "$GUEST_RUNTIME_SCRIPT" "$REMOTE_SETUP_DIR/guest-runtime-setup.sh"
}

resolve_agent_download_url() {
  [[ "$AGENT_SERVER_TAG" =~ ^agent-server-v[A-Za-z0-9._-]+$ ]] \
    || fail "AGENT_SERVER_TAG must pin an agent-server-v* release"
  AGENT_DOWNLOAD_URL="https://github.com/ariana-dot-dev/agent-server/releases/download/$AGENT_SERVER_TAG/ascii-agents-server-linux-x64"
}

run_guest_setup() {
  if [ "$SKIP_RUNTIME_SETUP" != "1" ]; then
    log "running runtime setup in guest"
    ssh_root "env \
      MACHINE_NAME=$(quote "$VM_NAME") \
      MACHINE_IP=$(quote "$VM_IPV6") \
      MACHINE_SUBDOMAIN=$(quote "$MACHINE_SUBDOMAIN") \
      AGENT_DOWNLOAD_URL=$(quote "$AGENT_DOWNLOAD_URL") \
      AGENT_SERVER_TAG=$(quote "$AGENT_SERVER_TAG") \
      AGENT_PORT=$(quote "$AGENT_PORT") \
      BACKEND_URL=$(quote "$BACKEND_URL") \
      BOX_CLI_API_URL=$(quote "$BOX_CLI_API_URL") \
      BOX_CLI_CHANNEL=$(quote "$BOX_CLI_CHANNEL") \
      BOX_CLI_MODE=$(quote "$BOX_CLI_MODE") \
      BOX_CLI_TAG=$(quote "$BOX_CLI_TAG") \
      AGENTS_SERVER_CHANNEL=$(quote "$AGENTS_SERVER_CHANNEL") \
      ENABLE_AGENT_V6_PROXY=$(quote "$ENABLE_AGENT_V6_PROXY") \
      NODE_PUBLIC_IPV4=$(quote "$NODE_PUBLIC_IPV4") \
      WEBRTC_PORT_MIN=$(quote "$WEBRTC_PORT_MIN") \
      WEBRTC_PORT_MAX=$(quote "$WEBRTC_PORT_MAX") \
      bash $(quote "$REMOTE_SETUP_DIR/guest-runtime-setup.sh")" | tee "$VM_DIR/runtime-setup.log"
    ssh_root "cat /opt/ascii-agent/provision-result.env" > "$VM_DIR/runtime-result.env"
    chmod 600 "$VM_DIR/runtime-result.env"
  else
    log "skipping runtime setup"
  fi
}

# ASC-187: a customer box must leave provisioning with ZERO node/operator
# credentials. Strip the throwaway key from the guest, close root SSH, prove
# the door is shut, then delete the node-side private key. Explicit key
# sources (SSH_PUBLIC_KEYS / SSH_AUTHORIZED_KEYS_FILE / SSH_PRIVATE_KEY_FILE)
# mean the operator asked for standing access, so the lockdown is skipped —
# that combination is for dev boxes only.
revoke_provision_access() {
  if [ -n "${SSH_PUBLIC_KEYS:-}" ] || [ -n "$SSH_AUTHORIZED_KEYS_FILE" ] || [ "$EPHEMERAL_PROVISION_KEY" != "1" ]; then
    log "WARNING: explicit SSH key source set; leaving guest root SSH open (dev mode, never for customer boxes)"
    return 0
  fi

  log "revoking provisioning access in guest"
  # 00- prefix matters: sshd is first-keyword-wins and Ubuntu ships
  # 50-cloud-init.conf, so this file must sort first to own PermitRootLogin.
  ssh_root "set -e
: > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin no\nPasswordAuthentication no\n' > /etc/ssh/sshd_config.d/00-ascii-lockdown.conf
chmod 644 /etc/ssh/sshd_config.d/00-ascii-lockdown.conf
systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true"

  local args=()
  mapfile -t args < <(ssh_base_args)
  if ssh -o BatchMode=yes "${args[@]}" "root@$VM_IPV6" true >/dev/null 2>&1; then
    fail "guest still accepts the provisioning key after revocation"
  fi
  log "guest root SSH closed; provisioning key rejected as expected"

  rm -f "$SSH_PRIVATE_KEY_FILE" "$SSH_PRIVATE_KEY_FILE.pub"
}

# Gateway->guest leg rides the cert-gateway's WireGuard mesh, same as Hetzner
# boxes (create.sh): the gateway container has no IPv6 of its own, so proxying
# to the guest's public v6 does NOT work — without a WG peer, boxes get 502s
# through their *.on.ascii.dev URLs. Failure here is deliberately non-fatal
# (the gateway falls back to the public IP), but on this fleet that fallback
# is known-broken, so treat warnings below seriously.
gateway_request() {
  local operation="$1"
  local payload="$2"
  local headers=(
    -H 'Content-Type: application/json'
    -H "X-Baremetal-Machine: $VM_NAME"
    -H "X-Baremetal-Expires: $GATEWAY_EXPIRES"
    -H "X-Baremetal-Capability: $GATEWAY_CAPABILITY"
  )
  [ -n "$GATEWAY_PROXY_URL" ] && [ -n "$GATEWAY_CAPABILITY" ] && [ -n "$GATEWAY_EXPIRES" ] \
    || fail "gateway capability is not configured"
  if [ -n "$GATEWAY_TARGET_IP" ]; then
    headers+=(-H "X-Baremetal-Target: $GATEWAY_TARGET_IP")
  fi
  curl -fsS -X POST "$GATEWAY_PROXY_URL" "${headers[@]}" \
    -d "$(printf '%s' "$payload" | jq -c --arg operation "$operation" '. + {operation: $operation}')"
}

bind_gateway_target() {
  [ "$SKIP_CERT_GATEWAY" != 1 ] || return 0
  local response target_capability
  response="$(gateway_request bind-target "$(jq -nc \
    --arg machineName "$VM_NAME" --arg targetIp "$VM_IPV6" \
    '{machineName: $machineName, targetIp: $targetIp}')")"
  target_capability="$(jq -er '.targetCapability' <<<"$response")"
  [[ "$target_capability" =~ ^[a-f0-9]{64}$ ]] || fail "backend returned an invalid target-bound gateway capability"
  GATEWAY_TARGET_IP="$VM_IPV6"
  GATEWAY_CAPABILITY="$target_capability"
}

setup_wireguard() {
  if [ "$SKIP_CERT_GATEWAY" = "1" ]; then
    log "skipping WireGuard mesh registration"
    return 0
  fi
  log "registering guest in the cert-gateway WireGuard mesh"

  # wireguard-tools is baked into the golden image; install is a fallback for
  # stock images only.
  ssh_root "command -v wg >/dev/null 2>&1 || (apt-get update -qq --allow-releaseinfo-change && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools)" \
    || { log "WARNING: wireguard-tools unavailable in guest; gateway will 502 for this box"; return 0; }

  local wg_pubkey wg_response wg_ip wg_server_pubkey wg_endpoint wg_server_ip
  # Keypair is generated on the guest; the private key never leaves it.
  wg_pubkey="$(ssh_root 'umask 077 && mkdir -p /etc/wireguard && wg genkey > /etc/wireguard/box.key && wg pubkey < /etc/wireguard/box.key' || true)"
  if [ -z "$wg_pubkey" ]; then
    log "WARNING: WireGuard keygen failed; gateway will 502 for this box"
    return 0
  fi

  wg_response="$(gateway_request register-wireguard "$(jq -nc \
    --arg machineName "$VM_NAME" --arg publicKey "$wg_pubkey" --arg publicIp "$VM_IPV6" \
    '{machineName: $machineName, publicKey: $publicKey, publicIp: $publicIp}')" || true)"
  wg_ip="$(jq -r '.wg_ip // empty' <<<"$wg_response" 2>/dev/null || true)"
  wg_server_pubkey="$(jq -r '.server_pubkey // empty' <<<"$wg_response" 2>/dev/null || true)"
  wg_endpoint="$(jq -r '.endpoint // empty' <<<"$wg_response" 2>/dev/null || true)"
  wg_server_ip="$(jq -r '.server_wg_ip // empty' <<<"$wg_response" 2>/dev/null || true)"
  valid_wg_key() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
      && [ "$(printf '%s' "$value" | base64 -d 2>/dev/null | wc -c)" = 32 ]
  }
  valid_ipv4() {
    local value="$1" octet
    local -a octets=()
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$value"
    for octet in "${octets[@]}"; do [ "$octet" -le 255 ] || return 1; done
  }
  if ! valid_wg_key "$wg_pubkey" || ! valid_wg_key "$wg_server_pubkey" \
    || ! valid_ipv4 "$wg_ip" || ! valid_ipv4 "$wg_server_ip" \
    || ! [[ "$wg_endpoint" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):[0-9]{1,5}$ ]]; then
    log "WARNING: WireGuard registration returned invalid configuration"
    gateway_request unregister-wireguard "$(jq -nc --arg machineName "$VM_NAME" '{machineName: $machineName}')" >/dev/null || true
    return 0
  fi
  endpoint_port="${wg_endpoint##*:}"; endpoint_port="${endpoint_port%]}"
  if [ "$endpoint_port" -lt 1 ] || [ "$endpoint_port" -gt 65535 ]; then
    log "WARNING: WireGuard registration returned invalid endpoint port"
    gateway_request unregister-wireguard "$(jq -nc --arg machineName "$VM_NAME" '{machineName: $machineName}')" >/dev/null || true
    return 0
  fi

  ssh_root "umask 077 && cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = \$(cat /etc/wireguard/box.key)
Address = $wg_ip/16

[Peer]
PublicKey = $wg_server_pubkey
Endpoint = $wg_endpoint
AllowedIPs = $wg_server_ip/32
PersistentKeepalive = 25
WGEOF
systemctl enable wg-quick@wg0 >/dev/null 2>&1 && systemctl restart wg-quick@wg0" \
    || { log "WARNING: failed to bring up wg0 in guest"; return 0; }

  # Confirm the tunnel carries traffic; a dead committed tunnel means 502s, so
  # unregister the peer to restore the (public-IP) fallback path.
  if ssh_root "ping -c 1 -W 5 $wg_server_ip" >/dev/null 2>&1; then
    log "WireGuard tunnel established ($wg_ip -> $wg_server_ip)"
  else
    log "WARNING: WireGuard tunnel did not come up; unregistering peer"
    gateway_request unregister-wireguard "$(jq -nc --arg machineName "$VM_NAME" '{machineName: $machineName}')" >/dev/null || true
  fi
}

wait_for_http() {
  local name="$1"
  local url="$2"
  log "waiting for $name at $url"
  for _ in $(seq 1 90); do
    if curl -g -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      log "$name ready"
      return
    fi
    sleep 2
  done
  fail "$name did not become ready: $url"
}

register_route() {
  local subdomain="$1"
  local port="$2"
  local machine_name="$3"
  local response url

  response="$(gateway_request register-route "$(jq -nc \
    --arg subdomain "$subdomain" --arg targetIp "$VM_IPV6" --arg machineName "$machine_name" --argjson port "$port" \
    '{subdomain: $subdomain, targetIp: $targetIp, port: $port, machineName: $machineName}')")"
  url="$(printf '%s' "$response" | grep -o '"url":"[^"]*"' | cut -d'"' -f4 || true)"
  if [ -z "$url" ]; then
    fail "cert-gateway registration failed for $subdomain: $response"
  fi
  printf '%s\n' "$url"
}

register_cert_gateway() {
  MACHINE_URL=""
  DESKTOP_URL=""
  TEST_PORT_URL=""

  if [ "$SKIP_CERT_GATEWAY" = "1" ]; then
    log "skipping cert-gateway registration"
    return
  fi

  log "registering cert-gateway routes through scoped backend capability"
  MACHINE_URL="$(register_route "$MACHINE_SUBDOMAIN" "$AGENT_PORT" "$VM_NAME")"
  DESKTOP_URL="$(register_route "$MACHINE_SUBDOMAIN-desktop" 8090 "$VM_NAME-desktop")"
  if [ "$REGISTER_TEST_PORT" = "1" ]; then
    TEST_PORT_URL="$(register_route "$MACHINE_SUBDOMAIN-$TEST_PORT" "$TEST_PORT" "$VM_NAME-$TEST_PORT")"
  fi
}

write_machine_info() {
  local shared_key streaming_token streaming_host_id streaming_app_id pairing_success info_file
  info_file="$VM_DIR/machine-info.env"
  local result_file="$VM_DIR/runtime-result.env"

  if [ -f "$result_file" ]; then
    shared_key="$(grep '^SHARED_KEY=' "$result_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    streaming_token="$(grep '^STREAMING_TOKEN=' "$result_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    streaming_host_id="$(grep '^STREAMING_HOST_ID=' "$result_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    streaming_app_id="$(grep '^STREAMING_APP_ID=' "$result_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    pairing_success="$(grep '^PAIRING_SUCCESS=' "$result_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  else
    shared_key="$(grep '^SHARED_KEY=' "$VM_DIR/runtime-setup.log" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    streaming_token="$(grep '^STREAMING_TOKEN=' "$VM_DIR/runtime-setup.log" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    streaming_host_id="$(grep '^STREAMING_HOST_ID=' "$VM_DIR/runtime-setup.log" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    streaming_app_id="$(grep '^STREAMING_APP_ID=' "$VM_DIR/runtime-setup.log" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    pairing_success="$(grep '^PAIRING_SUCCESS=' "$VM_DIR/runtime-setup.log" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  fi

  {
    printf 'PROVIDER=baremetal\n'
    printf 'NODE_ID=%q\n' "$NODE_ID"
    printf 'MACHINE_NAME=%q\n' "$VM_NAME"
    printf 'MACHINE_ID=%q\n' "$VM_NAME"
    printf 'OWNERSHIP_ID=%q\n' "$OWNERSHIP_ID"
    printf 'CREATED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'MACHINE_IP=%q\n' "$VM_IPV6"
    printf 'MACHINE_IP_TYPE=IPv6\n'
    printf 'MACHINE_SUBDOMAIN=%q\n' "$MACHINE_SUBDOMAIN"
    printf 'MACHINE_URL=%q\n' "${MACHINE_URL:-}"
    printf 'DESKTOP_URL=%q\n' "${DESKTOP_URL:-}"
    printf 'TEST_PORT_URL=%q\n' "${TEST_PORT_URL:-}"
    printf 'SHARED_KEY=%q\n' "$shared_key"
    printf 'STREAMING_TOKEN=%q\n' "$streaming_token"
    printf 'STREAMING_HOST_ID=%q\n' "$streaming_host_id"
    printf 'STREAMING_APP_ID=%q\n' "$streaming_app_id"
    printf 'PAIRING_SUCCESS=%q\n' "$pairing_success"
    printf 'VM_INDEX=%q\n' "$VM_INDEX"
    printf 'PUBLIC_MAC=%q\n' "$PUBLIC_MAC"
    printf 'NAT_MAC=%q\n' "$NAT_MAC"
    printf 'NAT_IP=%q\n' "$NAT_IP"
    printf 'PUBLIC_TAP=%q\n' "$PUBLIC_TAP"
    printf 'NAT_TAP=%q\n' "$NAT_TAP"
    printf 'PUBLIC_FILTER=%q\n' "$PUBLIC_FILTER"
    printf 'NAT_FILTER=%q\n' "$NAT_FILTER"
    printf 'SSH_ENDPOINT=%q\n' "$SSH_ENDPOINT"
    printf 'AGENT_ENDPOINT=%q\n' "$AGENT_ENDPOINT"
    # Quoted, not %q: the value has a space and both node-agents strip
    # surrounding double quotes but do not unescape backslashes.
    printf 'SSH_HOST_PUBKEY="%s"\n' "$SSH_HOST_PUBKEY"
    printf 'WEBRTC_UDP_RANGE=%q\n' "$WEBRTC_PORT_MIN-$WEBRTC_PORT_MAX"
    printf 'BASE_IMAGE=%q\n' "$BASE_IMAGE"
    printf 'AGENT_SERVER_TAG=%q\n' "$AGENT_SERVER_TAG"
    printf 'BOX_CLI_TAG=%q\n' "$BOX_CLI_TAG"
    printf 'VM_DIR=%q\n' "$VM_DIR"
  } > "$info_file"
  chmod 600 "$info_file"
}

print_summary() {
  echo ""
  echo "Name: $VM_NAME"
  echo "IP: $VM_IPV6"
  echo "IP_TYPE: IPv6"
  echo "PROVIDER: baremetal"
  echo "URL: ${MACHINE_URL:-}"
  echo "DESKTOP_URL: ${DESKTOP_URL:-}"
  echo "SSH_ENDPOINT: $SSH_ENDPOINT"
  echo "SSH_HOST_PUBKEY: $SSH_HOST_PUBKEY"
  if [ -n "${TEST_PORT_URL:-}" ]; then
    echo "TEST_PORT_URL: $TEST_PORT_URL"
  fi
  echo "MACHINE_INFO_FILE: $VM_DIR/machine-info.env"
}

main() {
  require_root
  VCPU_TOPOLOGY_SPEC="$(vm_vcpu_topology_spec "$VCPUS")" || fail "invalid VCPUS"
  need_cmd virsh
  need_cmd virt-install
  need_cmd python3
  need_cmd qemu-img
  need_cmd cloud-localds
  need_cmd curl
  need_cmd ssh
  need_cmd scp
  need_cmd openssl
  need_cmd ssh-keygen
  need_cmd python3
  need_cmd jq
  need_cmd flock

  vm_io_validate_policy || fail "invalid VM I/O policy"
  vm_io_require_policy_support || fail "virsh does not support the VM I/O policy"

  validate_requested_network
  phase image find_base_image
  phase allocation allocate_ip
  validate_names
  derive_network_names

  VM_DIR="$VM_ROOT/$VM_NAME"
  if ! mkdir "$VM_DIR"; then
    fail "VM_DIR already exists or cannot be created: $VM_DIR"
  fi
  VM_DIR_CREATED=1
  chmod 755 "$VM_DIR"
  ensure_provision_ssh_key
  ensure_vm_host_identity

  ensure_libvirt
  # The invocation atomically owns the unique VM directory and has now proven
  # no pre-existing libvirt domain uses the requested name. Only beyond this
  # point may EXIT cleanup mutate a domain with that name.
  DOMAIN_NAME_OWNED=1
  write_cloud_init
  resolve_node_public_ipv4
  write_ownership_witness
  phase gateway-bind bind_gateway_target
  phase ipv4-doorway setup_ipv4_doorway
  resolve_agent_download_url
  phase libvirt create_vm
  phase boot-to-ssh wait_for_ssh
  phase wireguard setup_wireguard
  copy_guest_inputs
  phase guest-runtime run_guest_setup

  if [ "$SKIP_RUNTIME_SETUP" != "1" ]; then
    phase agent-ready wait_for_http "agent" "http://[$VM_IPV6]:$AGENT_PORT/health"
    phase desktop-ready wait_for_http "moonlight-web" "http://[$VM_IPV6]:8090/"
  fi

  revoke_provision_access

  write_machine_info
  phase gateway register_cert_gateway
  write_machine_info
  print_summary
}

main "$@"
