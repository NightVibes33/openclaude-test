#!/usr/bin/env bash
set -euo pipefail

for target in /var/lib/ascii /etc/ascii; do
  source="$(findmnt -n -o SOURCE -T "$target")"
  source="${source%%\[*}"
  if ! lsblk -s -n -o TYPE "$source" 2>/dev/null | grep -qx crypt; then
    echo "$target is not backed by dm-crypt; refusing bare-metal workload access" >&2
    exit 1
  fi
done
