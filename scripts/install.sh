#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 apache|kubeflow|both" >&2
  exit 2
}

profile="${1:-}"
case "$profile" in
  apache|kubeflow|both) ;;
  *) usage ;;
esac

for command_name in helm kubectl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "$repo_root/versions.env"

kubectl cluster-info >/dev/null

helm repo add --force-update yunikorn https://apache.github.io/yunikorn-release
helm repo add --force-update spark https://apache.github.io/spark-kubernetes-operator
helm repo add --force-update spark-operator https://kubeflow.github.io/spark-operator
helm repo update

helm upgrade --install yunikorn yunikorn/yunikorn \
  --namespace yunikorn \
  --create-namespace \
  --version "$YUNIKORN_CHART_VERSION" \
  --values "$repo_root/deploy/values/yunikorn.yaml" \
  --wait --timeout 10m

helm upgrade --install gemius-spark-platform \
  "$repo_root/charts/gemius-spark-platform" \
  --namespace yunikorn \
  --wait --timeout 5m

if [[ "$profile" == "apache" || "$profile" == "both" ]]; then
  helm upgrade --install apache-spark-operator spark/spark-kubernetes-operator \
    --namespace spark-operator-apache \
    --create-namespace \
    --version "$APACHE_OPERATOR_CHART_VERSION" \
    --values "$repo_root/deploy/values/apache-operator.yaml" \
    --wait --timeout 10m
fi

if [[ "$profile" == "kubeflow" || "$profile" == "both" ]]; then
  helm upgrade --install kubeflow-spark-operator spark-operator/spark-operator \
    --namespace spark-operator-kubeflow \
    --create-namespace \
    --version "$KUBEFLOW_OPERATOR_CHART_VERSION" \
    --values "$repo_root/deploy/values/kubeflow-operator.yaml" \
    --wait --timeout 10m
fi

echo "Installed shared platform with operator profile: $profile"

