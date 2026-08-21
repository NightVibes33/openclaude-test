#!/usr/bin/env bash

validate_image_provenance_file() {
  local provenance_file="$1"
  jq -e '
    (.sourceCommit | test("^[a-f0-9]{40}$"))
    and (.inputsSha256 | test("^[a-f0-9]{64}$"))
    and (.imageSha256 | test("^[a-f0-9]{64}$"))
    and (.agentServerSha256 | test("^[a-f0-9]{64}$"))
    and (.boxCliSha256 | test("^[a-f0-9]{64}$"))
  ' "$provenance_file" >/dev/null
}
