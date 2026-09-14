#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

require_root
: "${NODE_IP:?set NODE_IP to this node ens3 address}"
: "${KUBERNETES_MINOR:=1.35}"
: "${CONTAINERD_ROOT:=/mnt/ssd1/containerd}"
: "${KUBELET_ROOT:=/mnt/ssd2/kubelet}"
: "${REQUIRED_STORAGE_MOUNTS:=/mnt/ssd1:/mnt/ssd2}"

is_ipv4 "$NODE_IP" || fail "NODE_IP must be a valid IPv4 address: $NODE_IP"
for state_path in "$CONTAINERD_ROOT" "$KUBELET_ROOT"; do
  [[ "$state_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "invalid state path: $state_path"
  [[ "$state_path" != *"/../"* && "$state_path" != */.. ]] || \
    fail "state path must not contain '..': $state_path"
  [[ "$state_path" != / ]] || fail "state path must not be the filesystem root"
done

IFS=: read -r -a storage_mounts <<<"$REQUIRED_STORAGE_MOUNTS"
(( ${#storage_mounts[@]} > 0 )) || fail "REQUIRED_STORAGE_MOUNTS must not be empty"
for storage_mount in "${storage_mounts[@]}"; do
  [[ "$storage_mount" =~ ^/[A-Za-z0-9._/-]*$ ]] || \
    fail "invalid required storage mount: $storage_mount"
  mountpoint -q "$storage_mount" || fail "$storage_mount is not mounted"
  [[ "$(findmnt -n -o FSTYPE --target "$storage_mount")" == "ext4" ]] || \
    fail "$storage_mount is not ext4"
done

log "configuring kernel modules and sysctls"
install -m 0644 /dev/stdin /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

install -m 0644 /dev/stdin /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

log "disabling swap"
swapoff -a
if grep -Eq '^[^#].+[[:space:]]swap[[:space:]]' /etc/fstab; then
  sed -ri '/^[^#].+[[:space:]]swap[[:space:]]/ s/^/# disabled by gemius-k8s: /' /etc/fstab
fi

log "installing container runtime prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl gpg containerd conntrack ebtables ethtool socat

log "configuring containerd state at $CONTAINERD_ROOT"
install -d -m 0755 /etc/containerd "$CONTAINERD_ROOT"
containerd_config="$(mktemp)"
trap 'rm -f "$containerd_config"' EXIT
containerd config default >"$containerd_config"
sed -ri "s|^root = .*$|root = \"$CONTAINERD_ROOT\"|" "$containerd_config"
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/g' "$containerd_config"
install -m 0644 "$containerd_config" /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

log "installing Kubernetes ${KUBERNETES_MINOR} packages"
install -d -m 0755 /etc/apt/keyrings
curl --fail --show-error --silent --location \
  "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes --output /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' \
  "$KUBERNETES_MINOR" >/etc/apt/sources.list.d/kubernetes.list
chmod 0644 /etc/apt/sources.list.d/kubernetes.list
# The Gemius APT proxy does not allow this repository, while direct HTTPS is
# available. Scope the bypass to the two Kubernetes repository hosts only.
install -m 0644 /dev/stdin /etc/apt/apt.conf.d/95-kubernetes-direct <<'EOF'
Acquire::http::Proxy::pkgs.k8s.io "DIRECT";
Acquire::https::Proxy::pkgs.k8s.io "DIRECT";
Acquire::http::Proxy::prod-cdn.packages.k8s.io "DIRECT";
Acquire::https::Proxy::prod-cdn.packages.k8s.io "DIRECT";
EOF
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null

log "placing kubelet state and pod ephemeral storage at $KUBELET_ROOT"
install -d -m 0755 "$KUBELET_ROOT" /etc/systemd/system/kubelet.service.d
install -m 0644 /dev/stdin /etc/systemd/system/kubelet.service.d/20-gemius-node.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--root-dir=${KUBELET_ROOT} --node-ip=${NODE_IP}"
EOF
systemctl daemon-reload
systemctl enable kubelet

log "prepared $(hostname -f) (${NODE_IP})"
