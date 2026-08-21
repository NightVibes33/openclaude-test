#!/usr/bin/env bash
# Bootstrap a fresh Debian bare-metal server into an ascii bare-metal node.
#
# Codifies the manual node0 setup (docs/bare-metal-node0-implementation-plan.md,
# Phases 1-3) so every next node (node1, ...) is one command. Run ON the node as
# root, from a repo checkout or an unpacked node-manager release tarball:
#
#   sudo NODE_ID=node1 \
#     IPV6_PREFIX64=2001:41d0:xxxx:yyyy \
#     BAREMETAL_NODE_AGENT_ALLOWED_IPS=<backend-ip-or-cidr> \
#     NODE_MANAGER_CHANNEL=staging \
#     R2_QEMU_IMAGES_ENV=/path/to/r2-qemu-images.env \
#     ./bare-metal-node/bootstrap-node.sh
#
# What it does (idempotent):
#   1. Requires /etc/ascii/r2-qemu-images.env (installed from R2_QEMU_IMAGES_ENV
#      if given) so every exact image id can be fetched and checksum-verified.
#   2. Installs libvirt/QEMU + tooling.
#   3. Persists IPv6 forwarding + proxy_ndp sysctls (per-VM NDP entries are
#      managed by provision-vm.sh at create/delete time).
#   4. Defines the routed libvirt network libvirt-<NODE_ID> (bridge br-<NODE_ID>,
#      host <IPV6_PREFIX64>:100::1/80) and ensures the NAT `default` network
#      (create-time IPv4 egress for dependency downloads).
#   5. Creates /var/lib/ascii/{images,vms,baremetal/{leases,ownership}}.
#   6. Writes /etc/ascii/baremetal-node-agent.env (mode 600) with the node-level
#      overrides provision-vm.sh needs (NODE_ID, IPV6_PREFIX,
#      PUBLIC_INTERFACE) and a generated HMAC secret unless one is provided.
#   7. Installs the node manager from its checksummed release channel
#      (update-node-manager.sh; NODE_MANAGER_CHANNEL or NODE_MANAGER_TAG), or —
#      dev escape hatch — compiles it from this checkout when
#      NODE_MANAGER_BUILD_FROM_SOURCE=1. Enables ascii-node-manager.service and
#      the auto-update timer.
#   8. UFW: allow 22 from anywhere, 8787 only from BAREMETAL_NODE_AGENT_ALLOWED_IPS.
#
# NOT done here (printed as next steps): copying a box-base-*.qcow2 into
# /var/lib/ascii/images/, and registering the node via the dashboard's Add-node
# form (paste the blob this script prints).
set -euo pipefail

log() { printf '\033[1;32m[bootstrap]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[bootstrap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "run as root"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Runs from a repo checkout (dev) or an unpacked release tarball (fleet).
[ -d "$REPO_ROOT/backend/agents-server" ] || [ -x "$REPO_ROOT/bin/ascii-node-manager" ] \
  || fail "not running from a repo checkout or an unpacked node-manager release: $REPO_ROOT"

NODE_ID="${NODE_ID:-}"
[ -n "$NODE_ID" ] || fail "NODE_ID is required (e.g. node1)"

# The server's routed /64 (OVH assigns one per dedicated server). VMs live in
# the <prefix64>:100::/80 subrange, same convention as node0.
IPV6_PREFIX64="${IPV6_PREFIX64:-}"
if [ -z "$IPV6_PREFIX64" ]; then
  detected="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | grep -v '^f' | head -1 | cut -d/ -f1 || true)"
  if [ -n "$detected" ]; then
    IPV6_PREFIX64="$(printf '%s' "$detected" | awk -F: '{printf "%s:%s:%s:%s", $1, $2, $3, $4}')"
    log "IPV6_PREFIX64 not set; detected $IPV6_PREFIX64 from $detected"
  else
    fail "IPV6_PREFIX64 is required (no global IPv6 found to detect it from)"
  fi
fi
VM_IPV6_PREFIX="${IPV6_PREFIX64}:100"
HOST_BRIDGE_IP="${VM_IPV6_PREFIX}::1"

PUBLIC_INTERFACE="${PUBLIC_INTERFACE:-$(ip -o -4 route show to default | awk '{print $5}' | head -1)}"
[ -n "$PUBLIC_INTERFACE" ] || fail "could not detect PUBLIC_INTERFACE"

BIND_ADDR="${BAREMETAL_NODE_AGENT_BIND:-0.0.0.0}"
PORT="${BAREMETAL_NODE_AGENT_PORT:-8787}"
ALLOWED_IPS="${BAREMETAL_NODE_AGENT_ALLOWED_IPS:-}"
[ -n "$ALLOWED_IPS" ] || fail "BAREMETAL_NODE_AGENT_ALLOWED_IPS is required"
ALLOWED_IPS="$ALLOWED_IPS,127.0.0.1,::1"

ENV_FILE=/etc/ascii/baremetal-node-agent.env
# Re-running bootstrap must not clobber a secret the backend already knows
# (rotations rewrite the env file): reuse the existing secrets unless an
# explicit override is passed.
EXISTING_SECRET=""
EXISTING_SECRET_PREVIOUS=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_SECRET="$(grep '^BAREMETAL_NODE_AGENT_HMAC_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  EXISTING_SECRET_PREVIOUS="$(grep '^BAREMETAL_NODE_AGENT_HMAC_SECRET_PREVIOUS=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
fi
HMAC_SECRET="${BAREMETAL_NODE_AGENT_HMAC_SECRET:-${EXISTING_SECRET:-$(openssl rand -hex 32)}}"
HMAC_SECRET_PREVIOUS="${BAREMETAL_NODE_AGENT_HMAC_SECRET_PREVIOUS:-$EXISTING_SECRET_PREVIOUS}"

# Node-manager release stream (ASC-286). The update timer follows the channel;
# an exact NODE_MANAGER_TAG wins for this install, NODE_MANAGER_TAG_PIN keeps
# winning until unset. Re-runs reuse the channel already in the env file.
EXISTING_CHANNEL=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_CHANNEL="$(grep '^NODE_MANAGER_CHANNEL=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
fi
NODE_MANAGER_CHANNEL="${NODE_MANAGER_CHANNEL:-$EXISTING_CHANNEL}"
NODE_MANAGER_TAG="${NODE_MANAGER_TAG:-}"
NODE_MANAGER_TAG_PIN="${NODE_MANAGER_TAG_PIN:-}"
NODE_MANAGER_BUILD_FROM_SOURCE="${NODE_MANAGER_BUILD_FROM_SOURCE:-0}"
if [ "$NODE_MANAGER_BUILD_FROM_SOURCE" != "1" ] && [ -z "$NODE_MANAGER_CHANNEL" ] && [ -z "$NODE_MANAGER_TAG" ]; then
  fail "NODE_MANAGER_CHANNEL (e.g. staging, ascii-prod) or NODE_MANAGER_TAG is required — or NODE_MANAGER_BUILD_FROM_SOURCE=1 for a dev build from this checkout"
fi

# R2 creds for the qemu golden-image buckets. Existing file wins (rotations
# rewrite it in place); otherwise install from R2_QEMU_IMAGES_ENV; otherwise
# fail here, before the system is touched.
R2_IMAGES_ENV=/etc/ascii/r2-qemu-images.env
if [ ! -f "$R2_IMAGES_ENV" ]; then
  R2_QEMU_IMAGES_ENV="${R2_QEMU_IMAGES_ENV:-}"
  { [ -n "$R2_QEMU_IMAGES_ENV" ] && [ -f "$R2_QEMU_IMAGES_ENV" ]; } || fail \
    "$R2_IMAGES_ENV missing — copy it from an existing node (on this node: sudo scp <node0>:/etc/ascii/r2-qemu-images.env /etc/ascii/) or pass R2_QEMU_IMAGES_ENV=<path>"
  mkdir -p /etc/ascii
  install -m 600 -o root -g root "$R2_QEMU_IMAGES_ENV" "$R2_IMAGES_ENV"
  log "installed $R2_IMAGES_ENV from $R2_QEMU_IMAGES_ENV"
fi
AGENTS_SERVER_CHANNEL="${AGENTS_SERVER_CHANNEL:-ascii-prod}"
AGENT_SERVER_TAG="${AGENT_SERVER_TAG:-}"
BOX_CLI_TAG="${BOX_CLI_TAG:-}"
BOX_CLI_CHANNEL="${BOX_CLI_CHANNEL:-prod}"
BOX_CLI_MODE="${BOX_CLI_MODE:-box}"

TLS_DIR=/etc/ascii/node-agent-tls
NETWORK_NAME="libvirt-$NODE_ID"
BRIDGE_NAME="br-$NODE_ID"

log "node=$NODE_ID iface=$PUBLIC_INTERFACE vm-prefix=${VM_IPV6_PREFIX}::/80 repo=$REPO_ROOT"

log "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-system-x86 libvirt-daemon-system virtinst qemu-utils \
  cloud-image-utils python3 ufw curl rsync openssl jq cryptsetup tpm2-tools >/dev/null
systemctl enable --now libvirtd >/dev/null 2>&1 || systemctl enable --now libvirtd.service

# ASC-192: guest disks, ownership metadata, node credentials, and image-store
# credentials must all resolve through dm-crypt. There is no attestation escape
# hatch: a physically removable plaintext disk is the threat this protects.
for storage_target in /var/lib/ascii /etc/ascii; do
  [ -d "$storage_target" ] || fail "$storage_target is missing; migrate encrypted storage before bootstrap"
  storage_source="$(findmnt -n -o SOURCE -T "$storage_target")"
  storage_source="${storage_source%%\[*}"
  lsblk -s -n -o TYPE "$storage_source" 2>/dev/null | grep -qx crypt \
    || fail "$storage_target is not backed by dm-crypt; run encrypt-node-storage.sh first"
done
log "verified dm-crypt backing for VM data and node credentials"

log "persisting IPv6 forwarding + proxy_ndp sysctls"
cat > /etc/sysctl.d/99-ascii-baremetal.conf <<EOF
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.$PUBLIC_INTERFACE.proxy_ndp=1
EOF
sysctl -p /etc/sysctl.d/99-ascii-baremetal.conf >/dev/null

if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
  log "libvirt network $NETWORK_NAME already defined"
else
  log "defining routed libvirt network $NETWORK_NAME (bridge $BRIDGE_NAME)"
  tmp_xml="$(mktemp)"
  cat > "$tmp_xml" <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='route' dev='$PUBLIC_INTERFACE'/>
  <bridge name='$BRIDGE_NAME' stp='on' delay='0'/>
  <ip family='ipv6' address='$HOST_BRIDGE_IP' prefix='80'/>
</network>
EOF
  virsh net-define "$tmp_xml" >/dev/null
  rm -f "$tmp_xml"
fi
virsh net-start "$NETWORK_NAME" >/dev/null 2>&1 || true
virsh net-autostart "$NETWORK_NAME" >/dev/null

# NAT IPv4 network for create-time downloads (install-all-deps.sh upstreams are
# IPv4-only while guest public inbound is IPv6-only).
virsh net-start default >/dev/null 2>&1 || true
virsh net-autostart default >/dev/null 2>&1 || true

log "creating /var/lib/ascii directories"
mkdir -p /var/lib/ascii/images /var/lib/ascii/vms \
  /var/lib/ascii/baremetal/leases /var/lib/ascii/baremetal/ownership
chmod 700 /var/lib/ascii/baremetal/ownership

# Self-signed TLS cert, pinned by the backend at registration (no CA, no DNS,
# no renewal — 10 years). SANs are by IP because the backend dials by IP.
PUBLIC_IPV4="${PUBLIC_IPV4:-$(ip -o -4 addr show "$PUBLIC_INTERFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)}"
[ -n "$PUBLIC_IPV4" ] || fail "could not detect PUBLIC_IPV4 on $PUBLIC_INTERFACE"
HOST_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | grep -v '^f' | head -1 | cut -d/ -f1 || true)"
SAN="IP:$PUBLIC_IPV4${HOST_IPV6:+,IP:$HOST_IPV6}"
if [ -f "$TLS_DIR/cert.pem" ] && [ -f "$TLS_DIR/key.pem" ]; then
  log "TLS cert already present in $TLS_DIR"
else
  log "generating self-signed TLS cert (SAN $SAN, 10y)"
  mkdir -p "$TLS_DIR"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" -days 3650 \
    -subj "/CN=$NODE_ID" -addext "subjectAltName=$SAN" 2>/dev/null
  chmod 600 "$TLS_DIR/key.pem"
fi

log "writing $ENV_FILE"
mkdir -p /etc/ascii
cat > "$ENV_FILE" <<EOF
BAREMETAL_NODE_ID=$NODE_ID
BAREMETAL_NODE_AGENT_BIND=$BIND_ADDR
BAREMETAL_NODE_AGENT_PORT=$PORT
BAREMETAL_NODE_AGENT_HMAC_SECRET=$HMAC_SECRET
${HMAC_SECRET_PREVIOUS:+BAREMETAL_NODE_AGENT_HMAC_SECRET_PREVIOUS=$HMAC_SECRET_PREVIOUS}
BAREMETAL_NODE_AGENT_ALLOWED_IPS=$ALLOWED_IPS
# The active node-manager release: binary and the provision/delete scripts it
# shells out to always come from the same verified release (ASC-286).
BAREMETAL_NODE_AGENT_REPO=/opt/ascii/node-manager/current
BAREMETAL_NODE_AGENT_MAX_CLOCK_SKEW_SECONDS=300
BAREMETAL_NODE_AGENT_MAX_BODY_BYTES=65536
BAREMETAL_NODE_AGENT_ENV_FILE=$ENV_FILE
BAREMETAL_NODE_AGENT_TLS_CERT=$TLS_DIR/cert.pem
BAREMETAL_NODE_AGENT_TLS_KEY=$TLS_DIR/key.pem
BAREMETAL_ABUSE_MONITOR=1
BAREMETAL_ABUSE_MONITOR_INTERVAL_SECONDS=10
BAREMETAL_ABUSE_BPF_PIN_ROOT=/sys/fs/bpf/ascii-node-agent

# Node-manager release stream (ASC-286): the update timer follows the channel;
# NODE_MANAGER_TAG_PIN wins while set (rollback = pin the last good tag).
${NODE_MANAGER_CHANNEL:+NODE_MANAGER_CHANNEL=$NODE_MANAGER_CHANNEL}
${NODE_MANAGER_TAG_PIN:+NODE_MANAGER_TAG_PIN=$NODE_MANAGER_TAG_PIN}

# Node-level overrides picked up by provision-vm.sh via the node-agent's
# environment pass-through (its defaults encode node0's values).
NODE_ID=$NODE_ID
IPV6_PREFIX=$VM_IPV6_PREFIX
IPV6_PREFIX_LENGTH=80
PUBLIC_INTERFACE=$PUBLIC_INTERFACE
NODE_PUBLIC_IPV4=$PUBLIC_IPV4
PUBLIC_NETWORK=$NETWORK_NAME

# Passed through to provision-vm.sh.
AGENTS_SERVER_CHANNEL=$AGENTS_SERVER_CHANNEL
${AGENT_SERVER_TAG:+AGENT_SERVER_TAG=$AGENT_SERVER_TAG}
${BOX_CLI_TAG:+BOX_CLI_TAG=$BOX_CLI_TAG}
BOX_CLI_CHANNEL=$BOX_CLI_CHANNEL
BOX_CLI_MODE=$BOX_CLI_MODE
${BACKEND_URL:+BACKEND_URL=$BACKEND_URL}
BAREMETAL_PROVISION_CONCURRENCY=${BAREMETAL_PROVISION_CONCURRENCY:-2}
BAREMETAL_MEMORY_RESERVE_MB=${BAREMETAL_MEMORY_RESERVE_MB:-16384}
BAREMETAL_DISK_RESERVE_GB=${BAREMETAL_DISK_RESERVE_GB:-100}
BAREMETAL_VM_DISK_BUDGET_GB=${BAREMETAL_VM_DISK_BUDGET_GB:-70}
BAREMETAL_MAX_VCPU_OVERCOMMIT=${BAREMETAL_MAX_VCPU_OVERCOMMIT:-2}
CLEANUP_ON_FAILURE=1
EOF
chmod 600 "$ENV_FILE"

# The embedded eBPF program is loaded at runtime even when the userspace binary
# ships prebuilt, so bpffs setup cannot live only in a build branch.
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
mkdir -p /sys/fs/bpf/ascii-node-agent

# Reconcile env must exist before the node-manager unit starts (the unit
# Requires ascii-baremetal-reconcile.service).
log "writing /etc/ascii/baremetal-reconcile.env"
cat > /etc/ascii/baremetal-reconcile.env <<EOF
PUBLIC_INTERFACE=$PUBLIC_INTERFACE
NODE_PUBLIC_IPV4=$PUBLIC_IPV4
NAT_NETWORK=default
VM_ROOT=/var/lib/ascii/vms
EOF
chmod 0644 /etc/ascii/baremetal-reconcile.env

# Install the node manager from its checksummed, immutable release (ASC-286) —
# no more compiling a synced source tree in place. update-node-manager.sh
# verifies the release, stages it under /opt/ascii/node-manager, installs the
# systemd units + root-owned safety scripts, and atomically flips `current`;
# its timer keeps the node on the channel afterwards.
UPDATER="$SCRIPT_DIR/update-node-manager.sh"
RELEASES_DIR=/opt/ascii/node-manager/releases
export NODE_MANAGER_ENV_FILE="$ENV_FILE"
if [ "$NODE_MANAGER_BUILD_FROM_SOURCE" = "1" ]; then
  # Dev escape hatch: build this checkout, then stage + activate it exactly
  # like a release so the on-node layout never depends on the install path.
  AGENT_CRATE="$SCRIPT_DIR/node-manager-rs"
  [ -d "$AGENT_CRATE" ] || fail "NODE_MANAGER_BUILD_FROM_SOURCE=1 needs a repo checkout with $AGENT_CRATE"
  log "building node manager from source (dev only; fleet nodes install releases)"
  apt-get install -y -qq build-essential >/dev/null
  if ! command -v cargo >/dev/null 2>&1; then
    log "installing rust toolchain via rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path >/dev/null
  fi
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  export PATH="$HOME/.cargo/bin:$PATH"
  rustup toolchain install nightly-2026-08-05 --profile minimal --component rust-src >/dev/null
  if ! command -v bpf-linker >/dev/null 2>&1; then
    cargo install bpf-linker --version 0.10.4 --locked
  fi
  cargo build --release --locked --manifest-path "$AGENT_CRATE/Cargo.toml"
  STAGE_NAME="source-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || date +%s)"
  STAGE="$RELEASES_DIR/$STAGE_NAME"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/bin" "$STAGE/bare-metal-node"
  install -m 0755 "$AGENT_CRATE/target/release/ascii-node-manager" "$STAGE/bin/ascii-node-manager"
  rsync -a --exclude node-manager-rs --exclude tests --exclude node-agent.py --exclude '*.md' \
    "$SCRIPT_DIR/" "$STAGE/bare-metal-node/"
  "$UPDATER" activate "$STAGE_NAME" --force
elif [ -n "$NODE_MANAGER_TAG" ]; then
  "$UPDATER" install "$NODE_MANAGER_TAG" --force
else
  "$UPDATER" check --apply
fi
systemctl enable --now ascii-baremetal-reconcile.service

ufw allow 22/tcp >/dev/null
if [ -n "$ALLOWED_IPS" ]; then
  log "configuring UFW (22 open, $PORT restricted to: $ALLOWED_IPS)"
  IFS=',' read -ra ips <<< "$ALLOWED_IPS"
  for ip in "${ips[@]}"; do
    ip="$(echo "$ip" | xargs)"
    [ -n "$ip" ] && ufw allow from "$ip" to any port "$PORT" proto tcp >/dev/null
  done
else
  log "configuring UFW (22 open, $PORT open to any caller — HMAC is the gate)"
  ufw allow "$PORT"/tcp >/dev/null
fi
ufw --force enable >/dev/null

# Restart once more now that UFW is settled: ExecStartPre restores forwarding
# rules and migrates existing domains.
systemctl restart ascii-node-manager.service

sleep 1
timestamp="$(date +%s)"
nonce="bootstrap-$(openssl rand -hex 8)"
body_hash="$(printf '' | sha256sum | awk '{print $1}')"
canonical="$(printf 'GET\n/health\n%s\n%s\n%s' "$timestamp" "$nonce" "$body_hash")"
signature="$(printf '%s' "$canonical" | openssl dgst -sha256 -hmac "$HMAC_SECRET" -hex | awk '{print $2}')"
if curl -fsSk "https://127.0.0.1:$PORT/health" \
  -H "X-Baremetal-Timestamp: $timestamp" -H "X-Baremetal-Nonce: $nonce" \
  -H "X-Baremetal-Signature: $signature" >/dev/null 2>&1; then
  log "node-manager authenticated health check passed on :$PORT (https)"
else
  fail "node-manager /health failed; check: journalctl -u ascii-node-manager -n 50"
fi

base_image="$(ls -1t /var/lib/ascii/images/box-base-*.qcow2 2>/dev/null | head -1 || true)"

# One-paste registration blob for the dashboard's "Add node" form. No capacity
# figure: the node manager is the source of truth and reports it live (ASC-286).
BLOB="$(jq -n \
  --arg nodeId "$NODE_ID" \
  --arg apiUrl "https://$PUBLIC_IPV4:$PORT" \
  --arg hmacSecret "$HMAC_SECRET" \
  --rawfile tlsCertPem "$TLS_DIR/cert.pem" \
  '{nodeId: $nodeId, apiUrl: $apiUrl, hmacSecret: $hmacSecret, tlsCertPem: $tlsCertPem}')"

cat <<EOF

── $NODE_ID bootstrapped ─────────────────────────────────────────────
 Registration blob — paste into dashboard → Bare metal nodes → Add node:

$BLOB

 Remaining steps:
 ✓ R2 image creds: $R2_IMAGES_ENV
 $( [ -n "$base_image" ] && echo "✓ base image present: $base_image" \
    || echo "1. Copy a base image:  scp node0:/var/lib/ascii/images/box-base-*.qcow2 /var/lib/ascii/images/  (or let the first provision fetch it from R2 — slower first park)" )
 2. Paste the blob above into the dashboard Add-node form.
 3. Health check from the caller:  curl -k https://$PUBLIC_IPV4:$PORT/health
──────────────────────────────────────────────────────────────────────
EOF
