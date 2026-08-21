#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-io.sh
source "$SCRIPT_DIR/lib/vm-io.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./bare-metal-node/tune-vm-io.sh [--apply] [--rollback] VM_NAME

Without --apply, prints the current and proposed vda policy without changing it.
The default policy clears absolute limits. --rollback restores the legacy
200 MiB/s and 2,000-IOPS limits.
EOF
}

fail() {
  printf '[tune-vm-io] ERROR: %s\n' "$*" >&2
  exit 1
}

print_command() {
  local domain="$1"
  local rollback="$2"
  shift 2
  local policy_args=()
  local arg

  if [ "$rollback" = 1 ]; then
    mapfile -t policy_args < <(vm_io_legacy_policy_args)
  else
    mapfile -t policy_args < <(vm_io_policy_args)
  fi
  printf 'virsh blkdeviotune %q vda' "$domain"
  for arg in "${policy_args[@]}" "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

apply=0
rollback=0
domain=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --rollback) rollback=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) fail "unknown option: $1" ;;
    *)
      [ -z "$domain" ] || fail 'exactly one VM_NAME is required'
      domain="$1"
      shift
      ;;
  esac
done

[ -n "$domain" ] || { usage >&2; exit 2; }
[[ "$domain" =~ ^box-[a-z0-9]+-[a-z0-9-]+$ ]] || fail "invalid VM name: $domain"
command -v virsh >/dev/null 2>&1 || fail 'virsh is required'

state="$(virsh domstate "$domain")" || fail "cannot read domain state: $domain"
case "$state" in
  'shut off'|shutoff|crashed)
    mutation_flags=(--config)
    query_flags=(--config)
    ;;
  *)
    mutation_flags=(--live --config)
    query_flags=(--live)
    ;;
esac

printf '[tune-vm-io] Current %s/vda policy (%s):\n' "$domain" "$state"
virsh blkdeviotune "$domain" vda "${query_flags[@]}"

if [ "$rollback" = 1 ]; then
  printf '[tune-vm-io] Proposed legacy capped policy:\n'
else
  vm_io_validate_policy || fail 'I/O policy validation failed'
  printf '[tune-vm-io] Proposed uncapped policy:\n'
fi
print_command "$domain" "$rollback" "${mutation_flags[@]}"

if [ "$apply" != 1 ]; then
  printf '[tune-vm-io] Dry run. Re-run with --apply to change this one domain.\n'
  exit 0
fi

if [ "$rollback" = 1 ]; then
  vm_io_apply_legacy_policy "$domain" vda "${mutation_flags[@]}" >/dev/null
else
  vm_io_apply_policy "$domain" vda "${mutation_flags[@]}" >/dev/null
fi

printf '[tune-vm-io] Effective %s/vda policy:\n' "$domain"
virsh blkdeviotune "$domain" vda "${query_flags[@]}"
