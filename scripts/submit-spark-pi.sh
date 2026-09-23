#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/submit-spark-pi.sh DECIMAL_PLACES

Submit a deterministic Pi calculation through the Apache Spark operator.
DECIMAL_PLACES must be an integer from 1 through 1000.

Optional environment variables:
  SPARK_PI_GROUP       YuniKorn group/namespace suffix (default: dev)
  SPARK_PI_NAMESPACE   Kubernetes namespace (default: spark-$SPARK_PI_GROUP)
  SPARK_PI_JOB_NAME    Explicit unique job name
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || {
  usage >&2
  exit 2
}

digits="$1"
[[ "$digits" =~ ^[0-9]+$ ]] || fail "DECIMAL_PLACES must be an integer"
(( 10#$digits >= 1 && 10#$digits <= 1000 )) || \
  fail "DECIMAL_PLACES must be between 1 and 1000"
digits="$((10#$digits))"

group="${SPARK_PI_GROUP:-dev}"
namespace="${SPARK_PI_NAMESPACE:-spark-$group}"
job_name="${SPARK_PI_JOB_NAME:-spark-pi-${digits}-$(date -u +%Y%m%d%H%M%S)}"
[[ "$group" =~ ^(prod|beta|dev|adhoc)$ ]] || fail "invalid group: $group"
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#namespace} -le 63 ]] || \
  fail "invalid namespace: $namespace"
[[ "$job_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#job_name} -le 48 ]] || \
  fail "job name must be a valid Kubernetes name of at most 48 characters"

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
python_source="$repo_root/examples/spark-pi/spark_pi.py"
application_template="$repo_root/examples/spark-pi/sparkapplication-parameterized.yaml"
[[ -f "$python_source" ]] || fail "missing Spark Pi source: $python_source"
[[ -f "$application_template" ]] || \
  fail "missing SparkApplication template: $application_template"

worker_nodes="$({
  kubectl get nodes -l gemius.io/node-role=spark-worker --no-headers
} | awk '$2 == "Ready" {print $1}')"
[[ -n "$worker_nodes" ]] || fail "no Ready nodes carry gemius.io/node-role=spark-worker"
worker_count="$(printf '%s\n' "$worker_nodes" | wc -l | tr -d '[:space:]')"
expected_nodes="$(printf '%s\n' "$worker_nodes" | LC_ALL=C sort | paste -sd, -)"
[[ "$worker_count" =~ ^[0-9]+$ && "$worker_count" -ge 1 ]] || \
  fail "could not determine the Ready Spark worker count"
[[ "$expected_nodes" =~ ^[a-z0-9.-]+(,[a-z0-9.-]+)*$ ]] || \
  fail "worker node names contain unsupported characters"

code_configmap="${job_name}-code"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
code_manifest="$tmp_dir/code-configmap.yaml"
application_manifest="$tmp_dir/sparkapplication.yaml"

kubectl -n "$namespace" create configmap "$code_configmap" \
  --from-file="spark_pi.py=$python_source" \
  --dry-run=client -o yaml >"$code_manifest"

sed \
  -e "s/__JOB_NAME__/$job_name/g" \
  -e "s/__CODE_CONFIGMAP__/$code_configmap/g" \
  -e "s/__NAMESPACE__/$namespace/g" \
  -e "s/__GROUP__/$group/g" \
  -e "s/__DIGITS__/$digits/g" \
  -e "s/__EXECUTORS__/$worker_count/g" \
  -e "s/__EXPECTED_NODES__/$expected_nodes/g" \
  "$application_template" >"$application_manifest"

if grep -Eq '__[A-Z_]+__' "$application_manifest"; then
  fail "the rendered SparkApplication still contains template placeholders"
fi

printf 'Validating %s against the Kubernetes API...\n' "$job_name"
kubectl apply --dry-run=server -f "$code_manifest" -f "$application_manifest" >/dev/null

printf 'Submitting Pi to %s decimal places with %s executors on: %s\n' \
  "$digits" "$worker_count" "$expected_nodes"
kubectl apply -f "$code_manifest" -f "$application_manifest"

cat <<EOF

Submitted $namespace/$job_name.

Watch:
  kubectl -n $namespace get sparkapplications.spark.apache.org $job_name -w

Result:
  kubectl -n $namespace logs ${job_name}-0-driver | grep -E 'PI_RESULT|DECIMAL_PLACES|CHUDNOVSKY_TERMS|EXECUTOR_NODES|VALIDATION'

Cleanup:
  kubectl -n $namespace delete sparkapplications.spark.apache.org $job_name
  kubectl -n $namespace delete configmap $code_configmap
EOF
