#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

require_root
: "${BOOTSTRAP_CONTROL_PLANE_IP:?set BOOTSTRAP_CONTROL_PLANE_IP}"
: "${BOOTSTRAP_CONTROL_PLANE_HOST:?set BOOTSTRAP_CONTROL_PLANE_HOST}"
: "${CONTROL_PLANE_ENDPOINT:?set CONTROL_PLANE_ENDPOINT to host-or-vip:port}"
: "${CLUSTER_NAME:=gemius-spark}"
: "${KUBERNETES_MINOR:=1.35}"
: "${POD_CIDR:=192.168.0.0/16}"
: "${SERVICE_CIDR:=10.96.0.0/12}"

is_ipv4 "$BOOTSTRAP_CONTROL_PLANE_IP" || \
  fail "invalid bootstrap control-plane IPv4 address: $BOOTSTRAP_CONTROL_PLANE_IP"
endpoint_host="${CONTROL_PLANE_ENDPOINT%:*}"
endpoint_port="${CONTROL_PLANE_ENDPOINT##*:}"
[[ "$BOOTSTRAP_CONTROL_PLANE_HOST" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || \
  fail "invalid bootstrap control-plane host: $BOOTSTRAP_CONTROL_PLANE_HOST"
[[ "$CLUSTER_NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail "invalid cluster name: $CLUSTER_NAME"
[[ "$endpoint_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && "$endpoint_port" =~ ^[0-9]+$ ]] || \
  fail "CONTROL_PLANE_ENDPOINT must be host-or-ip:port"
(( 10#$endpoint_port >= 1 && 10#$endpoint_port <= 65535 )) || \
  fail "CONTROL_PLANE_ENDPOINT port is outside 1-65535"

if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "existing control plane detected; leaving it in place"
  exit 0
fi

config_file="$(mktemp)"
trap 'rm -f "$config_file"' EXIT
install -m 0600 /dev/stdin "$config_file" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${BOOTSTRAP_CONTROL_PLANE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: stable-${KUBERNETES_MINOR}
clusterName: ${CLUSTER_NAME}
controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  certSANs:
    - ${endpoint_host}
    - ${BOOTSTRAP_CONTROL_PLANE_HOST}
    - ${BOOTSTRAP_CONTROL_PLANE_IP}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
serializeImagePulls: false
serverTLSBootstrap: true
EOF

log "pulling Kubernetes control-plane images"
kubeadm config images pull --config "$config_file"
log "initializing the control plane"
kubeadm init --config "$config_file" --upload-certs

install -d -m 0700 /root/.kube
install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
log "control plane initialized"
