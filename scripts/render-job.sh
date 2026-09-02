#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 apache|kubeflow VALUES_FILE" >&2
  exit 2
fi

operator="$1"
values_file="$2"
case "$operator" in
  apache|kubeflow) ;;
  *) echo "Unknown operator: $operator" >&2; exit 2 ;;
esac

if ! command -v helm >/dev/null 2>&1; then
  echo "Required command not found: helm" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helm template "example-$operator" "$repo_root/charts/gemius-spark-job" \
  --values "$values_file" \
  --set "operator=$operator"

