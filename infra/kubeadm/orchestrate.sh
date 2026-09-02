#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
# shellcheck source=inventory.env
source "$script_dir/inventory.env"
# shellcheck source=../../versions.env
source "$repo_root/versions.env"

require_command ssh
require_command scp
require_command tar
[[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]] || \
  fail "SSH_AUTH_SOCK must point to the jump host's working agent socket"
[[ "${#WORKER_HOSTS[@]}" -eq "${#WORKER_IPS[@]}" ]] || fail "worker inventory lengths differ"

ssh_options=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
all_hosts=("$CONTROL_PLANE_HOST" "${WORKER_HOSTS[@]}")
all_ips=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
remote_stage=/tmp/gemius-k8s-bootstrap

remote() {
  local host="$1"
  shift
  ssh "${ssh_options[@]}" "${REMOTE_USER}@${host}" "$@"
}

log "checking access and guarding against accidental cluster replacement"
for host in "${all_hosts[@]}"; do
  remote "$host" 'true' >/dev/null
done

if remote "$CONTROL_PLANE_HOST" 'test -f /etc/kubernetes/admin.conf'; then
  existing_cluster_config="$(
    remote "$CONTROL_PLANE_HOST" \
      "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get configmap kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}'"
  )"
  [[ "$existing_cluster_config" == *"clusterName: gemius-spark"* ]] || \
    fail "$CONTROL_PLANE_HOST already controls a different Kubernetes cluster"
fi

for host in "${WORKER_HOSTS[@]}"; do
  if remote "$host" 'test -f /etc/kubernetes/kubelet.conf'; then
    existing_server="$(remote "$host" "awk '/server:/ {print \$2; exit}' /etc/kubernetes/kubelet.conf")"
    [[ "$existing_server" == "https://${CONTROL_PLANE_HOST}:6443" ]] || \
      fail "$host is already joined to a different Kubernetes API: $existing_server"
  fi
done

log "copying node bootstrap scripts"
for host in "${all_hosts[@]}"; do
  remote "$host" "install -d -m 0700 '$remote_stage'"
  scp "${ssh_options[@]}" "$script_dir/common.sh" "$script_dir/prepare-node.sh" \
    "${REMOTE_USER}@${host}:${remote_stage}/"
  remote "$host" "bash -n '$remote_stage/common.sh' '$remote_stage/prepare-node.sh'"
done

log "preparing all four nodes"
for index in "${!all_hosts[@]}"; do
  host="${all_hosts[$index]}"
  ip="${all_ips[$index]}"
  remote "$host" \
    "NODE_IP='$ip' KUBERNETES_MINOR='$KUBERNETES_MINOR' bash '$remote_stage/prepare-node.sh'"
done

log "initializing ${CONTROL_PLANE_HOST} as the single control plane"
scp "${ssh_options[@]}" "$script_dir/common.sh" "$script_dir/init-control-plane.sh" \
  "$script_dir/install-helm.sh" "$script_dir/install-calico.sh" \
  "$script_dir/approve-kubelet-serving-csrs.sh" "$script_dir/inventory.env" \
  "${REMOTE_USER}@${CONTROL_PLANE_HOST}:${remote_stage}/"
remote "$CONTROL_PLANE_HOST" \
  "for script in '$remote_stage'/*.sh; do bash -n \"\$script\"; done"
remote "$CONTROL_PLANE_HOST" \
  "CONTROL_PLANE_IP='$CONTROL_PLANE_IP' CONTROL_PLANE_HOST='$CONTROL_PLANE_HOST' KUBERNETES_MINOR='$KUBERNETES_MINOR' POD_CIDR='$POD_CIDR' SERVICE_CIDR='$SERVICE_CIDR' bash '$remote_stage/init-control-plane.sh'"
remote "$CONTROL_PLANE_HOST" "HELM_VERSION='$HELM_VERSION' bash '$remote_stage/install-helm.sh'"
remote "$CONTROL_PLANE_HOST" \
  "CALICO_VERSION='$CALICO_VERSION' POD_CIDR='$POD_CIDR' bash '$remote_stage/install-calico.sh'"

log "joining worker nodes"
join_command="$(remote "$CONTROL_PLANE_HOST" 'kubeadm token create --ttl 2h --print-join-command')"
for host in "${WORKER_HOSTS[@]}"; do
  if remote "$host" 'test -f /etc/kubernetes/kubelet.conf'; then
    log "$host is already joined"
  else
    remote "$host" "$join_command --cri-socket unix:///run/containerd/containerd.sock"
  fi
done

log "validating and approving kubelet serving certificates"
remote "$CONTROL_PLANE_HOST" \
  "KUBECONFIG=/etc/kubernetes/admin.conf bash '$remote_stage/approve-kubelet-serving-csrs.sh'"

log "waiting for all nodes to become Ready"
remote "$CONTROL_PLANE_HOST" \
  "KUBECONFIG=/etc/kubernetes/admin.conf bash -c 'source $remote_stage/common.sh; wait_for_nodes ${#all_hosts[@]}'"

log "copying this repository to ${CONTROL_PLANE_HOST}:${REMOTE_INSTALL_DIR}"
archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
tar --exclude=.git -czf "$archive" -C "$repo_root" .
remote "$CONTROL_PLANE_HOST" "install -d -m 0755 '$REMOTE_INSTALL_DIR'"
scp "${ssh_options[@]}" "$archive" "${REMOTE_USER}@${CONTROL_PLANE_HOST}:${remote_stage}/repository.tar.gz"
remote "$CONTROL_PLANE_HOST" "tar -xzf '$remote_stage/repository.tar.gz' -C '$REMOTE_INSTALL_DIR'"

log "deploying YuniKorn and both Spark operators"
remote "$CONTROL_PLANE_HOST" \
  "cd '$REMOTE_INSTALL_DIR' && KUBECONFIG=/etc/kubernetes/admin.conf PLATFORM_VALUES=deploy/values/cluster-4vm.yaml ./scripts/install.sh both"

log "applying stable node-role labels"
control_plane_node="${CONTROL_PLANE_HOST%%.*}"
remote "$CONTROL_PLANE_HOST" \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node '$control_plane_node' gemius.io/node-role=control-plane --overwrite"
for host in "${WORKER_HOSTS[@]}"; do
  worker_node="${host%%.*}"
  remote "$CONTROL_PLANE_HOST" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node '$worker_node' gemius.io/node-role=spark-worker --overwrite"
done

log "cluster deployment complete"
remote "$CONTROL_PLANE_HOST" \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide"
remote "$CONTROL_PLANE_HOST" \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A"
