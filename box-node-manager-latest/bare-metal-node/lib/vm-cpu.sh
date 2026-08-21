#!/usr/bin/env bash

vm_vcpu_topology_spec() {
  local vcpus="${1:-}"

  if [[ ! "$vcpus" =~ ^[1-9][0-9]*$ ]]; then
    printf 'vCPU count must be a positive integer, got: %s\n' "$vcpus" >&2
    return 1
  fi

  printf '%s,sockets=1,cores=%s,threads=1\n' "$vcpus" "$vcpus"
}
