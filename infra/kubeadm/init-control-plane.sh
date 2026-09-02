#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

require_root
: "${CONTROL_PLANE_IP:?set CONTROL_PLANE_IP}"
: "${CONTROL_PLANE_HOST:?set CONTROL_PLANE_HOST}"
: "${KUBERNETES_MINOR:=1.35}"
: "${POD_CIDR:=192.168.0.0/16}"
: "${SERVICE_CIDR:=10.96.0.0/12}"

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
  advertiseAddress: ${CONTROL_PLANE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: stable-${KUBERNETES_MINOR}
clusterName: gemius-spark
controlPlaneEndpoint: ${CONTROL_PLANE_HOST}:6443
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  certSANs:
    - ${CONTROL_PLANE_HOST}
    - ${CONTROL_PLANE_IP}
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
