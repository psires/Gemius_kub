#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

if [[ -n "${INVENTORY_FILE:-}" ]]; then
  inventory_file="$INVENTORY_FILE"
elif [[ -f /etc/gemius-k8s/inventory.env ]]; then
  inventory_file=/etc/gemius-k8s/inventory.env
else
  inventory_file="$script_dir/inventory.env"
fi
[[ -f "$inventory_file" ]] || fail "inventory file not found: $inventory_file"
# shellcheck disable=SC1090
source "$inventory_file"

require_root
require_command kubectl
require_command openssl
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
export KUBECONFIG

declare -A expected_ip
[[ "${#NODE_HOSTS[@]}" -eq "${#NODE_IPS[@]}" ]] || fail "node inventory lengths differ"
for index in "${!NODE_HOSTS[@]}"; do
  node="${NODE_HOSTS[$index]%%.*}"
  expected_ip["$node"]="${NODE_IPS[$index]}"
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
