#!/usr/bin/env bash
# Pull, verify and activate an ascii-node-manager release on a bare-metal node.
#
# The node manager ships like everything else (ASC-286): tagged, checksummed,
# immutable GitHub releases in ariana-dot-dev/agent-server. This is the
# node-side puller:
#
#   update-node-manager.sh install <node-manager-vX.Y.Z[-<chan>N]>  # exact tag
#   update-node-manager.sh check [--apply]   # newest channel tag; --apply installs
#   update-node-manager.sh rollback          # flip back to the previous release
#   update-node-manager.sh status            # active/previous tags, in-flight provisions
#
# Channel + optional pin live in /etc/ascii/baremetal-node-agent.env:
#   NODE_MANAGER_CHANNEL   channel to follow (e.g. staging, ascii-prod)
#   NODE_MANAGER_TAG_PIN   exact tag; wins over the channel while set
#
# A release unpacks to /opt/ascii/node-manager/releases/<tag> (binary + the
# exact scripts it shells out to) and is activated by atomically flipping the
# `current` symlink, then restarting the service. Rollback is the same flip in
# reverse — no rebuild, no repo checkout on the node.
#
# Fleet rollout: publish a release on the channel; every node's
# ascii-node-manager-update.timer applies it within minutes. Fleet rollback:
# set NODE_MANAGER_TAG_PIN (or delete the bad release's tags, newest-wins).
set -euo pipefail

log() { printf '\033[1;32m[node-manager-update]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[node-manager-update] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "run as root"

RELEASE_REPO="ariana-dot-dev/agent-server"
ASSET="ascii-node-manager-linux-x64.tar.gz"
HOME_DIR=/opt/ascii/node-manager
RELEASES_DIR="$HOME_DIR/releases"
ENV_FILE="${NODE_MANAGER_ENV_FILE:-/etc/ascii/baremetal-node-agent.env}"
OWNERSHIP_ROOT=/var/lib/ascii/baremetal/ownership
LIBEXEC=/usr/local/libexec/ascii-baremetal
UNIT=ascii-node-manager.service
LEGACY_UNIT=ascii-baremetal-node-agent.service
KEEP_RELEASES=3

env_get() { # key -> value ('' when absent)
  [ -f "$ENV_FILE" ] || { printf ''; return; }
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE"
}

valid_tag() { [[ "$1" =~ ^node-manager-v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]]; }

active_tag() { basename "$(readlink "$HOME_DIR/current" 2>/dev/null || true)"; }
previous_tag() { basename "$(readlink "$HOME_DIR/previous" 2>/dev/null || true)"; }

# In-flight provisions (durable ownership records in state 'provisioning').
# Restarting mid-provision kills the provision's process group, so routine
# updates wait for a quiet node; --force overrides for emergencies. The manager
# reads its ownership root from BAREMETAL_OWNERSHIP_ROOT, so honor the same
# override — a hardcoded path on a node that moved it would count 0 in-flight
# forever and silently restart mid-provision.
inflight_provisions() {
  local root count=0 record
  root="$(env_get BAREMETAL_OWNERSHIP_ROOT)"
  [ -n "$root" ] || root="$OWNERSHIP_ROOT"
  for record in "$root"/*.json; do
    [ -f "$record" ] || continue
    grep -q '"state":"provisioning"' "$record" && count=$((count + 1))
  done
  printf '%s' "$count"
}

# Authenticated when a token is available (GITHUB_TOKEN in the env file or the
# invoking environment): the anonymous api.github.com limit is 60 req/hr/IP,
# and nodes behind one egress IP polling every 5 minutes starve each other —
# updates then silently stop until the window resets.
gh_curl() {
  local token
  token="$(env_get GITHUB_TOKEN)"
  [ -n "$token" ] || token="${GITHUB_TOKEN:-}"
  if [ -n "$token" ]; then
    curl -LfsS --retry 5 --retry-all-errors -H "Authorization: Bearer $token" "$@"
  else
    curl -LfsS --retry 5 --retry-all-errors "$@"
  fi
}

# Newest tag on the channel, resolved from the public artifact repo the same
# way the agent-server SDK does (matching-refs sorts reliably; /releases does
# not). Tags look like node-manager-v0.5.0-staging12.
resolve_channel_tag() {
  local channel="$1"
  gh_curl \
    "https://api.github.com/repos/$RELEASE_REPO/git/matching-refs/tags/node-manager-v" \
    | jq -r '.[].ref' \
    | sed -n "s|^refs/tags/node-manager-v\([0-9]\{1,\}\)\.\([0-9]\{1,\}\)\.\([0-9]\{1,\}\)-${channel}\([0-9]\{1,\}\)\$|\1 \2 \3 \4 node-manager-v\1.\2.\3-${channel}\4|p" \
    | sort -k1,1n -k2,2n -k3,3n -k4,4n \
    | tail -1 \
    | awk '{print $5}'
}

fetch_and_verify() { # tag -> unpacked release staged at $RELEASES_DIR/.staging-<tag>
  local tag="$1" release checksums expected actual work
  release="$(gh_curl "https://api.github.com/repos/$RELEASE_REPO/releases/tags/$tag")"
  jq -e '.draft == false and .immutable == true' <<<"$release" >/dev/null \
    || fail "$tag is not a published immutable GitHub release"
  checksums="$(curl -LfsS --retry 5 --retry-all-errors \
    "https://github.com/$RELEASE_REPO/releases/download/$tag/SHA256SUMS")"
  expected="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1; exit }' <<<"$checksums")"
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || fail "$tag has no checksum for $ASSET"

  work="$RELEASES_DIR/.staging-$tag"
  rm -rf "$work"
  mkdir -p "$work"
  curl -LfsS --retry 5 --retry-all-errors \
    "https://github.com/$RELEASE_REPO/releases/download/$tag/$ASSET" -o "$work/$ASSET"
  actual="$(sha256sum "$work/$ASSET" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { rm -rf "$work"; fail "$tag/$ASSET checksum mismatch"; }
  tar -xzf "$work/$ASSET" -C "$work"
  rm -f "$work/$ASSET"
  [ -x "$work/bin/ascii-node-manager" ] || { rm -rf "$work"; fail "$tag has no bin/ascii-node-manager"; }
  [ -f "$work/bare-metal-node/provision-vm.sh" ] || { rm -rf "$work"; fail "$tag has no provision scripts"; }
  log "verified $tag ($ASSET sha256 $actual)"
}

# Root-owned pieces that must live outside the release dir: safety scripts the
# unit runs as ExecStartPre, the units themselves, and this updater (so the
# timer always runs the updater the active release shipped).
install_system_pieces() {
  local src="$1/bare-metal-node"
  install -d -m 0755 "$LIBEXEC/lib"
  install -m 0755 "$src/reconcile-node.sh" "$LIBEXEC/reconcile-node.sh"
  install -m 0755 "$src/verify-encrypted-storage.sh" "$LIBEXEC/verify-encrypted-storage.sh"
  install -m 0755 "$src/ensure-tenant-isolation.sh" "$LIBEXEC/ensure-tenant-isolation.sh"
  install -m 0755 "$src/lib/isolate_domain_network.py" "$LIBEXEC/lib/isolate_domain_network.py"
  install -m 0755 "$src/update-node-manager.sh" "$LIBEXEC/update-node-manager.sh"
  install -m 0644 "$src/$UNIT" "/etc/systemd/system/$UNIT"
  install -m 0644 "$src/ascii-baremetal-reconcile.service" /etc/systemd/system/ascii-baremetal-reconcile.service
  install -m 0644 "$src/ascii-node-manager-update.service" /etc/systemd/system/ascii-node-manager-update.service
  install -m 0644 "$src/ascii-node-manager-update.timer" /etc/systemd/system/ascii-node-manager-update.timer
  systemctl daemon-reload
}

# The env file is the node's state and stays operator-owned, but two keys
# belong to the release flow: script resolution must follow the active release
# (legacy env files point at a repo checkout — new binary + old scripts would
# violate the same-release invariant), and a channel passed to this run is
# persisted so the timer can follow it.
migrate_env_file() {
  [ -f "$ENV_FILE" ] || return 0
  if ! grep -q '^BAREMETAL_NODE_AGENT_REPO=/opt/ascii/node-manager/current$' "$ENV_FILE"; then
    if grep -q '^BAREMETAL_NODE_AGENT_REPO=' "$ENV_FILE"; then
      sed -i 's|^BAREMETAL_NODE_AGENT_REPO=.*|BAREMETAL_NODE_AGENT_REPO=/opt/ascii/node-manager/current|' "$ENV_FILE"
    else
      printf 'BAREMETAL_NODE_AGENT_REPO=/opt/ascii/node-manager/current\n' >> "$ENV_FILE"
    fi
    log "pointed BAREMETAL_NODE_AGENT_REPO at /opt/ascii/node-manager/current"
  fi
  if [ -n "${NODE_MANAGER_CHANNEL:-}" ] && ! grep -q '^NODE_MANAGER_CHANNEL=' "$ENV_FILE"; then
    printf 'NODE_MANAGER_CHANNEL=%s\n' "$NODE_MANAGER_CHANNEL" >> "$ENV_FILE"
    log "persisted NODE_MANAGER_CHANNEL=$NODE_MANAGER_CHANNEL"
  fi
}

# One-time migration off the compiled-in-place node agent.
retire_legacy_agent() {
  if [ -f "/etc/systemd/system/$LEGACY_UNIT" ]; then
    log "retiring legacy $LEGACY_UNIT"
    systemctl disable --now "$LEGACY_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$LEGACY_UNIT"
    rm -f /usr/local/bin/ascii-baremetal-node-agent
    systemctl daemon-reload
  fi
}

prune_releases() {
  local keep tag dir
  keep="$(printf '%s\n%s\n' "$(active_tag)" "$(previous_tag)")"
  # Newest first by mtime; everything past KEEP_RELEASES that is not active or
  # previous goes.
  ls -1t "$RELEASES_DIR" 2>/dev/null | grep -v '^\.' | tail -n "+$((KEEP_RELEASES + 1))" \
    | while read -r tag; do
        grep -qx "$tag" <<<"$keep" && continue
        dir="$RELEASES_DIR/$tag"
        [ -d "$dir" ] && { log "pruning old release $tag"; rm -rf "$dir"; }
      done
}

activate() { # tag [--force]
  local tag="$1" force="${2:-}" inflight current
  current="$(active_tag)"
  [ "$current" = "$tag" ] && { log "$tag is already active"; return 0; }

  inflight="$(inflight_provisions)"
  if [ "$inflight" -gt 0 ] && [ "$force" != "--force" ]; then
    log "deferring: $inflight provision(s) in flight (re-run with --force to override)"
    exit 0
  fi

  [ -d "$RELEASES_DIR/$tag" ] || fail "release $tag is not staged"
  install_system_pieces "$RELEASES_DIR/$tag"
  migrate_env_file
  retire_legacy_agent

  # Atomic flip: build the new symlink next to `current`, then rename over it.
  # `previous` is rewritten only after the health gate passes: a candidate that
  # fails the gate must leave the rollback chain exactly as it found it.
  ln -sfn "$RELEASES_DIR/$tag" "$HOME_DIR/.current-next"
  mv -Tf "$HOME_DIR/.current-next" "$HOME_DIR/current"

  systemctl enable "$UNIT" >/dev/null 2>&1 || true
  systemctl enable --now ascii-node-manager-update.timer >/dev/null 2>&1 || true
  systemctl restart "$UNIT"

  # Post-restart health gate: a release that crash-loops must not stay active,
  # or every node on the channel bricks within one timer cycle and `check`
  # keeps reporting "up to date". 30s of sustained active covers the unit's
  # StartLimitBurst window; on failure flip back to the release that was
  # running seconds ago and say so loudly (the timer's journal is the pager).
  if ! verify_unit_stays_active; then
    if [ -n "$current" ]; then
      log "ERROR: $tag failed its post-restart health gate — rolling back to $current"
      # Full restore, not just the symlink: the candidate's units and helper
      # scripts are already installed system-wide and must revert with it
      # (same-release invariant). `previous` was never touched, so the
      # pre-update rollback target stays reachable.
      install_system_pieces "$RELEASES_DIR/$current"
      ln -sfn "$RELEASES_DIR/$current" "$HOME_DIR/.current-next"
      mv -Tf "$HOME_DIR/.current-next" "$HOME_DIR/current"
      systemctl restart "$UNIT" || true
      fail "$tag failed the health gate; rolled back to $current"
    fi
    fail "$tag failed its post-restart health gate and no previous release exists"
  fi

  if [ -n "$current" ]; then
    ln -sfn "$RELEASES_DIR/$current" "$HOME_DIR/previous"
  fi
  log "activated $tag (was: ${current:-none})"
  prune_releases
}

verify_unit_stays_active() {
  local i
  for i in 1 2 3 4 5 6; do
    sleep 5
    systemctl is-active --quiet "$UNIT" || return 1
  done
  return 0
}

cmd="${1:-status}"
case "$cmd" in
  install)
    tag="${2:-}"
    valid_tag "$tag" || fail "usage: $0 install <node-manager-vX.Y.Z[-<chan>N]>"
    mkdir -p "$RELEASES_DIR"
    if [ ! -d "$RELEASES_DIR/$tag" ]; then
      fetch_and_verify "$tag"
      mv "$RELEASES_DIR/.staging-$tag" "$RELEASES_DIR/$tag"
    fi
    activate "$tag" "${3:-}"
    ;;
  check)
    pin="$(env_get NODE_MANAGER_TAG_PIN)"
    if [ -n "$pin" ]; then
      valid_tag "$pin" || fail "NODE_MANAGER_TAG_PIN is not a node-manager-v* tag: $pin"
      target="$pin"
      log "pin present: $pin"
    else
      channel="$(env_get NODE_MANAGER_CHANNEL)"
      [ -n "$channel" ] || fail "NODE_MANAGER_CHANNEL is not set in $ENV_FILE (and no NODE_MANAGER_TAG_PIN)"
      target="$(resolve_channel_tag "$channel")"
      [ -n "$target" ] || fail "no node-manager release found on channel '$channel'"
      log "newest on channel '$channel': $target"
    fi
    current="$(active_tag)"
    if [ "$current" = "$target" ]; then
      log "up to date ($current)"
      exit 0
    fi
    log "update available: ${current:-none} -> $target"
    [ "${2:-}" = "--apply" ] || exit 0
    exec "$0" install "$target"
    ;;
  rollback)
    prev="$(previous_tag)"
    [ -n "$prev" ] || fail "no previous release recorded"
    log "rolling back to $prev"
    activate "$prev" --force
    ;;
  # Activate an already-staged release dir by name. Used by bootstrap-node.sh
  # for dev source builds (staged as source-<sha>); everything else should go
  # through `install`, which fetches and checksum-verifies.
  activate)
    name="${2:-}"
    [ -n "$name" ] && [[ "$name" != */* ]] || fail "usage: $0 activate <staged-release-name> [--force]"
    activate "$name" "${3:-}"
    ;;
  status)
    echo "active:   $(active_tag)"
    echo "previous: $(previous_tag)"
    echo "in-flight provisions: $(inflight_provisions)"
    echo "channel:  $(env_get NODE_MANAGER_CHANNEL)"
    pin="$(env_get NODE_MANAGER_TAG_PIN)"
    [ -n "$pin" ] && echo "pin:      $pin"
    systemctl is-active "$UNIT" >/dev/null 2>&1 && echo "service:  active" || echo "service:  NOT active"
    ;;
  *)
    fail "usage: $0 {install <tag> [--force]|check [--apply]|rollback|status}"
    ;;
esac
