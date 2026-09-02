#!/usr/bin/env bash
set -euo pipefail

if ! command -v helm >/dev/null 2>&1; then
  echo "Required command not found: helm" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

helm lint "$repo_root/charts/gemius-spark-platform"
helm lint "$repo_root/charts/gemius-spark-platform" \
  --values "$repo_root/deploy/values/cluster-4vm.yaml"
helm lint "$repo_root/charts/gemius-spark-platform" \
  --values "$repo_root/deploy/values/cluster-4vm-temporary-coexistence.yaml"
helm lint "$repo_root/charts/gemius-spark-job"

helm template platform "$repo_root/charts/gemius-spark-platform" \
  >"$tmp_dir/platform.yaml"
helm template platform-4vm "$repo_root/charts/gemius-spark-platform" \
  --values "$repo_root/deploy/values/cluster-4vm.yaml" \
  >"$tmp_dir/platform-4vm.yaml"
helm template apache "$repo_root/charts/gemius-spark-job" \
  --values "$repo_root/examples/jobs/apache-dev.yaml" \
  --set operator=apache >"$tmp_dir/apache.yaml"
helm template kubeflow "$repo_root/charts/gemius-spark-job" \
  --values "$repo_root/examples/jobs/kubeflow-dev.yaml" \
  --set operator=kubeflow >"$tmp_dir/kubeflow.yaml"

grep -q '^apiVersion: spark.apache.org/v1$' "$tmp_dir/apache.yaml"
grep -q '^apiVersion: sparkoperator.k8s.io/v1beta2$' "$tmp_dir/kubeflow.yaml"
grep -q 'name: spark-prod' "$tmp_dir/platform.yaml"
grep -q 'name: spark-adhoc' "$tmp_dir/platform.yaml"
grep -q 'value: namespace' "$tmp_dir/platform.yaml"
grep -q 'memory: "84Gi"' "$tmp_dir/platform-4vm.yaml"

bash -n "$repo_root/scripts/install.sh"
bash -n "$repo_root/scripts/render-job.sh"
bash -n "$repo_root/scripts/validate.sh"
for script in "$repo_root"/infra/kubeadm/*.sh; do
  bash -n "$script"
done
PYTHONPYCACHEPREFIX="$tmp_dir/pycache" \
  python3 -m py_compile "$repo_root/images/spark-pex/pex_runner.py"

echo "All local validations passed"
