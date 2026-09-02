#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
# shellcheck source=inventory.env
source "$script_dir/inventory.env"

require_root
require_command kubectl
require_command openssl
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
export KUBECONFIG

declare -A expected_ip
control_plane_node="${CONTROL_PLANE_HOST%%.*}"
expected_ip["$control_plane_node"]="$CONTROL_PLANE_IP"
for index in "${!WORKER_HOSTS[@]}"; do
  worker_node="${WORKER_HOSTS[$index]%%.*}"
  expected_ip["$worker_node"]="${WORKER_IPS[$index]}"
done

mapfile -t pending_csrs < <(
  kubectl get csr -o go-template='{{range .items}}{{if not .status.conditions}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
)

approved=0
for csr in "${pending_csrs[@]}"; do
  [[ -n "$csr" ]] || continue
  signer="$(kubectl get csr "$csr" -o jsonpath='{.spec.signerName}')"
  [[ "$signer" == "kubernetes.io/kubelet-serving" ]] || continue

  requestor="$(kubectl get csr "$csr" -o jsonpath='{.spec.username}')"
  node="${requestor#system:node:}"
  [[ "$requestor" == "system:node:$node" && -n "${expected_ip[$node]:-}" ]] || \
    fail "refusing CSR $csr from unexpected requestor $requestor"

  request_file="$(mktemp)"
  kubectl get csr "$csr" -o jsonpath='{.spec.request}' | base64 --decode >"$request_file"
  subject="$(openssl req -in "$request_file" -noout -subject -nameopt RFC2253)"
  request_text="$(openssl req -in "$request_file" -noout -text)"
  rm -f "$request_file"

  [[ "$subject" == *"CN=system:node:$node"* && "$subject" == *"O=system:nodes"* ]] || \
    fail "refusing CSR $csr with unexpected subject: $subject"
  [[ "$request_text" == *"DNS:$node"* ]] || fail "refusing CSR $csr without DNS SAN for $node"
  [[ "$request_text" == *"IP Address:${expected_ip[$node]}"* ]] || \
    fail "refusing CSR $csr without expected IP SAN ${expected_ip[$node]}"

  kubectl certificate approve "$csr"
  approved=$((approved + 1))
done

log "approved $approved validated kubelet serving certificate request(s)"
