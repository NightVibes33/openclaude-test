#!/usr/bin/env bash

VM_TOTAL_BYTES_SEC="${VM_TOTAL_BYTES_SEC:-0}"
VM_TOTAL_IOPS_SEC="${VM_TOTAL_IOPS_SEC:-0}"
VM_LEGACY_TOTAL_BYTES_SEC=209715200
VM_LEGACY_TOTAL_IOPS_SEC=2000

vm_io_error() {
  printf 'invalid VM I/O policy: %s\n' "$*" >&2
  return 1
}

vm_io_require_nonnegative_integer() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] \
    || vm_io_error "$name must be a non-negative integer, got: $value"
}

vm_io_validate_policy() {
  vm_io_require_nonnegative_integer VM_TOTAL_BYTES_SEC "$VM_TOTAL_BYTES_SEC" || return
  vm_io_require_nonnegative_integer VM_TOTAL_IOPS_SEC "$VM_TOTAL_IOPS_SEC"
}

vm_io_require_policy_support() {
  local help_text flag token found
  local required_flags=(
    --total-bytes-sec-max
    --total-bytes-sec-max-length
    --total-iops-sec-max
    --total-iops-sec-max-length
  )

  help_text="$(virsh help blkdeviotune 2>/dev/null)" \
    || { vm_io_error 'virsh cannot describe blkdeviotune'; return; }
  for flag in "${required_flags[@]}"; do
    found=0
    for token in $help_text; do
      token="${token#[}"
      token="${token%]}"
      token="${token%,}"
      if [ "$token" = "$flag" ]; then
        found=1
        break
      fi
    done
    [ "$found" = 1 ] || { vm_io_error "virsh blkdeviotune lacks $flag"; return; }
  done
}

vm_io_policy_args() {
  printf '%s\n' \
    --total-bytes-sec "$VM_TOTAL_BYTES_SEC" \
    --total-bytes-sec-max 0 \
    --total-bytes-sec-max-length 0 \
    --total-iops-sec "$VM_TOTAL_IOPS_SEC" \
    --total-iops-sec-max 0 \
    --total-iops-sec-max-length 0
}

vm_io_legacy_policy_args() {
  printf '%s\n' \
    --total-bytes-sec "$VM_LEGACY_TOTAL_BYTES_SEC" \
    --total-bytes-sec-max 0 \
    --total-bytes-sec-max-length 0 \
    --total-iops-sec "$VM_LEGACY_TOTAL_IOPS_SEC" \
    --total-iops-sec-max 0 \
    --total-iops-sec-max-length 0
}

vm_io_apply_policy() {
  local domain="$1"
  local device="$2"
  shift 2
  local policy_args=()

  vm_io_validate_policy || return
  vm_io_require_policy_support || return
  mapfile -t policy_args < <(vm_io_policy_args)
  virsh blkdeviotune "$domain" "$device" "${policy_args[@]}" "$@"
}

vm_io_apply_legacy_policy() {
  local domain="$1"
  local device="$2"
  shift 2
  local policy_args=()

  vm_io_require_policy_support || return
  mapfile -t policy_args < <(vm_io_legacy_policy_args)
  virsh blkdeviotune "$domain" "$device" "${policy_args[@]}" "$@"
}
