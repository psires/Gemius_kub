#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

require_root
require_command kubectl
require_command helm
: "${CALICO_VERSION:=v3.32.2}"
: "${POD_CIDR:=192.168.0.0/16}"
export KUBECONFIG=/etc/kubernetes/admin.conf

log "installing Calico ${CALICO_VERSION} with pod CIDR ${POD_CIDR}"
helm repo add --force-update projectcalico https://docs.tigera.io/calico/charts
helm repo update projectcalico
helm upgrade --install calico-crds projectcalico/crd.projectcalico.org.v1 \
  --namespace tigera-operator \
  --create-namespace \
  --version "$CALICO_VERSION" \
  --wait --timeout 10m
helm upgrade --install calico projectcalico/tigera-operator \
  --namespace tigera-operator \
  --version "$CALICO_VERSION" \
  --set installation.calicoNetwork.ipPools[0].cidr="$POD_CIDR" \
  --set installation.calicoNetwork.ipPools[0].encapsulation=VXLAN \
  --set installation.calicoNetwork.ipPools[0].natOutgoing=Enabled \
  --set installation.calicoNetwork.ipPools[0].nodeSelector="all()" \
  --wait --timeout 10m

kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=5m
log "Calico installed"
