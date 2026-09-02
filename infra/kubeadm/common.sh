#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[gemius-k8s] %s\n' "$*"
}

fail() {
  printf '[gemius-k8s] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "run this script as root"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

wait_for_nodes() {
  local expected="$1"
  local deadline=$((SECONDS + 600))
  local ready

  while (( SECONDS < deadline )); do
    ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {count++} END {print count+0}')"
    if [[ "$ready" -eq "$expected" ]]; then
      return 0
    fi
    sleep 10
  done

  kubectl get nodes -o wide || true
  fail "only $ready of $expected nodes became Ready within 10 minutes"
}
