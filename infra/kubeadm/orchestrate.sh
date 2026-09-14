#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"
# shellcheck source=../../versions.env
source "$repo_root/versions.env"

usage() {
  cat <<'EOF'
Usage:
  ./infra/kubeadm/orchestrate.sh --control-planes N [options]

Required:
  --control-planes N     Odd number of stacked control-plane/etcd nodes.

Options:
  --inventory FILE       Inventory file (default: infra/kubeadm/inventory.env).
  --platform-values FILE Repository-relative platform values file
                         (default: deploy/values/cluster-4vm.yaml).
  --plan                 Validate inputs and print node roles without SSH.
  --help                 Show this help.

The first N nodes in NODE_HOSTS/NODE_IPS become control-plane nodes. Every
remaining node becomes a Spark worker. For N greater than one, the inventory
must specify a stable load-balancer or virtual-IP CONTROL_PLANE_ENDPOINT.
EOF
}

control_plane_count=""
inventory_file="$script_dir/inventory.env"
platform_values_rel=deploy/values/cluster-4vm.yaml
plan_only=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --control-planes)
      [[ "$#" -ge 2 ]] || fail "--control-planes requires a value"
      control_plane_count="$2"
      shift 2
      ;;
    --inventory)
      [[ "$#" -ge 2 ]] || fail "--inventory requires a file"
      inventory_file="$2"
      shift 2
      ;;
    --platform-values)
      [[ "$#" -ge 2 ]] || fail "--platform-values requires a file"
      platform_values_rel="$2"
      shift 2
      ;;
    --plan)
      plan_only=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$control_plane_count" =~ ^[0-9]+$ ]] || \
  fail "--control-planes must be a positive odd integer"
(( control_plane_count >= 1 )) || fail "at least one control-plane node is required"
(( control_plane_count % 2 == 1 )) || \
  fail "control-plane count must be odd so stacked etcd has useful quorum"
[[ -f "$inventory_file" ]] || fail "inventory file not found: $inventory_file"
[[ "$platform_values_rel" != /* && "$platform_values_rel" != *..* ]] || \
  fail "--platform-values must be a repository-relative path without '..'"
[[ -f "$repo_root/$platform_values_rel" ]] || \
  fail "platform values file not found: $repo_root/$platform_values_rel"

# shellcheck disable=SC1090
source "$inventory_file"

[[ "$(declare -p NODE_HOSTS 2>/dev/null)" == "declare -a "* ]] || \
  fail "inventory must define NODE_HOSTS as an array"
[[ "$(declare -p NODE_IPS 2>/dev/null)" == "declare -a "* ]] || \
  fail "inventory must define NODE_IPS as an array"
: "${CONTROL_PLANE_ENDPOINT:?inventory must define CONTROL_PLANE_ENDPOINT}"
: "${CLUSTER_NAME:=gemius-spark}"
: "${POD_CIDR:=192.168.0.0/16}"
: "${SERVICE_CIDR:=10.96.0.0/12}"
: "${REMOTE_USER:=root}"
: "${REMOTE_INSTALL_DIR:=/opt/gemius-kub}"
: "${CONTAINERD_ROOT:=/mnt/ssd1/containerd}"
: "${KUBELET_ROOT:=/mnt/ssd2/kubelet}"
: "${REQUIRED_STORAGE_MOUNTS:=/mnt/ssd1:/mnt/ssd2}"

[[ "$CLUSTER_NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail "invalid cluster name: $CLUSTER_NAME"
[[ "${#NODE_HOSTS[@]}" -eq "${#NODE_IPS[@]}" ]] || fail "node inventory lengths differ"
(( control_plane_count < ${#NODE_HOSTS[@]} )) || \
  fail "inventory needs at least one Spark worker after the N control-plane nodes"
for state_path in "$CONTAINERD_ROOT" "$KUBELET_ROOT"; do
  [[ "$state_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "invalid state path: $state_path"
  [[ "$state_path" != *"/../"* && "$state_path" != */.. && "$state_path" != / ]] || \
    fail "unsafe state path: $state_path"
done
[[ "$REQUIRED_STORAGE_MOUNTS" =~ ^/[A-Za-z0-9._/-]*(:/[A-Za-z0-9._/-]*)*$ ]] || \
  fail "invalid REQUIRED_STORAGE_MOUNTS list"

endpoint_host="${CONTROL_PLANE_ENDPOINT%:*}"
endpoint_port="${CONTROL_PLANE_ENDPOINT##*:}"
[[ "$endpoint_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || \
  fail "invalid host or IPv4 address in CONTROL_PLANE_ENDPOINT"
[[ "$endpoint_port" =~ ^[0-9]+$ ]] || \
  fail "CONTROL_PLANE_ENDPOINT must include a numeric port"
(( 10#$endpoint_port >= 1 && 10#$endpoint_port <= 65535 )) || \
  fail "CONTROL_PLANE_ENDPOINT port is outside 1-65535"

for index in "${!NODE_HOSTS[@]}"; do
  host="${NODE_HOSTS[$index]}"
  ip="${NODE_IPS[$index]}"
  [[ "$host" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail "invalid node host: $host"
  node_name="${host%%.*}"
  (( ${#node_name} <= 63 )) || fail "node name exceeds 63 characters: $node_name"
  [[ "$node_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
    fail "invalid Kubernetes node name derived from $host: $node_name"
  is_ipv4 "$ip" || fail "invalid IPv4 address for $host: $ip"

  for ((previous = 0; previous < index; previous++)); do
    [[ "$host" != "${NODE_HOSTS[$previous]}" ]] || fail "duplicate node host: $host"
    [[ "$ip" != "${NODE_IPS[$previous]}" ]] || fail "duplicate node IP: $ip"
  done
done

control_plane_hosts=("${NODE_HOSTS[@]:0:control_plane_count}")
control_plane_ips=("${NODE_IPS[@]:0:control_plane_count}")
worker_hosts=("${NODE_HOSTS[@]:control_plane_count}")
worker_ips=("${NODE_IPS[@]:control_plane_count}")
all_hosts=("${NODE_HOSTS[@]}")
all_ips=("${NODE_IPS[@]}")
primary_control_plane="${control_plane_hosts[0]}"
primary_control_plane_ip="${control_plane_ips[0]}"

if (( control_plane_count > 1 )); then
  for index in "${!control_plane_hosts[@]}"; do
    node_name="${control_plane_hosts[$index]%%.*}"
    if [[ "$endpoint_host" == "${control_plane_hosts[$index]}" ||
          "$endpoint_host" == "$node_name" ||
          "$endpoint_host" == "${control_plane_ips[$index]}" ]]; then
      fail "N>1 requires a stable API load-balancer/VIP endpoint, not a control-plane node address"
    fi
  done
fi

log "deployment plan: ${control_plane_count} control plane(s), ${#worker_hosts[@]} Spark worker(s)"
log "cluster: ${CLUSTER_NAME}; shared API endpoint: ${CONTROL_PLANE_ENDPOINT}"
log "storage: containerd=${CONTAINERD_ROOT}; kubelet=${KUBELET_ROOT}; required mounts=${REQUIRED_STORAGE_MOUNTS}"
for index in "${!control_plane_hosts[@]}"; do
  log "control-plane[$((index + 1))]: ${control_plane_hosts[$index]} (${control_plane_ips[$index]})"
done
for index in "${!worker_hosts[@]}"; do
  log "spark-worker[$((index + 1))]: ${worker_hosts[$index]} (${worker_ips[$index]})"
done
log "platform values: ${platform_values_rel}"

if [[ "$plan_only" == true ]]; then
  log "plan validation complete; no remote connections or changes were made"
  exit 0
fi

require_command ssh
require_command scp
require_command tar
[[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]] || \
  fail "SSH_AUTH_SOCK must point to the jump host's working agent socket"

ssh_options=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
remote_stage=/tmp/gemius-k8s-bootstrap
archive=""

cleanup() {
  if [[ -n "$archive" && -f "$archive" ]]; then
    rm -f "$archive"
  fi
}
trap cleanup EXIT

remote() {
  local host="$1"
  shift
  ssh "${ssh_options[@]}" "${REMOTE_USER}@${host}" "$@"
}

log "checking access and guarding against accidental cluster replacement"
for index in "${!all_hosts[@]}"; do
  host="${all_hosts[$index]}"
  remote "$host" 'true' >/dev/null

  if remote "$host" 'test -f /etc/kubernetes/admin.conf'; then
    (( index < control_plane_count )) || \
      fail "$host is a control-plane node but the requested N assigns it as a worker"
    existing_cluster_config="$(
      remote "$host" \
        "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get configmap kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}'"
    )"
    [[ "$existing_cluster_config" == *"clusterName: ${CLUSTER_NAME}"* ]] || \
      fail "$host already controls a different Kubernetes cluster"
    [[ "$existing_cluster_config" == *"controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT}"* ]] || \
      fail "$host belongs to a cluster with a different shared API endpoint"
  elif remote "$host" 'test -f /etc/kubernetes/kubelet.conf'; then
    (( index >= control_plane_count )) || \
      fail "$host is already joined as a worker but the requested N assigns it as control plane"
    existing_server="$(remote "$host" "awk '/server:/ {print \$2; exit}' /etc/kubernetes/kubelet.conf")"
    [[ "$existing_server" == "https://${CONTROL_PLANE_ENDPOINT}" ]] || \
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

log "preparing all ${#all_hosts[@]} nodes"
for index in "${!all_hosts[@]}"; do
  remote "${all_hosts[$index]}" \
    "NODE_IP='${all_ips[$index]}' KUBERNETES_MINOR='$KUBERNETES_MINOR' CONTAINERD_ROOT='$CONTAINERD_ROOT' KUBELET_ROOT='$KUBELET_ROOT' REQUIRED_STORAGE_MOUNTS='$REQUIRED_STORAGE_MOUNTS' bash '$remote_stage/prepare-node.sh'"
done

log "staging control-plane and cluster installation scripts"
for host in "${control_plane_hosts[@]}"; do
  scp "${ssh_options[@]}" "$script_dir/common.sh" "$script_dir/init-control-plane.sh" \
    "$script_dir/install-helm.sh" "$script_dir/install-calico.sh" \
    "$script_dir/approve-kubelet-serving-csrs.sh" \
    "${REMOTE_USER}@${host}:${remote_stage}/"
  scp "${ssh_options[@]}" "$inventory_file" \
    "${REMOTE_USER}@${host}:${remote_stage}/inventory.env"
  remote "$host" \
    "for script in '$remote_stage'/*.sh; do bash -n \"\$script\"; done"
done

log "initializing $primary_control_plane as the first control plane"
remote "$primary_control_plane" \
  "BOOTSTRAP_CONTROL_PLANE_IP='$primary_control_plane_ip' BOOTSTRAP_CONTROL_PLANE_HOST='$primary_control_plane' CONTROL_PLANE_ENDPOINT='$CONTROL_PLANE_ENDPOINT' CLUSTER_NAME='$CLUSTER_NAME' KUBERNETES_MINOR='$KUBERNETES_MINOR' POD_CIDR='$POD_CIDR' SERVICE_CIDR='$SERVICE_CIDR' bash '$remote_stage/init-control-plane.sh'"
remote "$primary_control_plane" "HELM_VERSION='$HELM_VERSION' bash '$remote_stage/install-helm.sh'"
remote "$primary_control_plane" \
  "CALICO_VERSION='$CALICO_VERSION' POD_CIDR='$POD_CIDR' bash '$remote_stage/install-calico.sh'"

log "verifying that the shared API endpoint reaches the first control plane"
remote "$primary_control_plane" \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw=/readyz"

worker_join_command="$(
  remote "$primary_control_plane" 'kubeadm token create --ttl 2h --print-join-command'
)"

if (( control_plane_count > 1 )); then
  log "uploading short-lived control-plane certificates"
  certificate_key="$(
    remote "$primary_control_plane" \
      "kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n 1"
  )"
  [[ "$certificate_key" =~ ^[a-f0-9]{64}$ ]] || \
    fail "kubeadm did not return a valid certificate key"
  control_plane_join_command="$worker_join_command --control-plane --certificate-key $certificate_key"

  log "joining additional control-plane nodes sequentially"
  for ((index = 1; index < control_plane_count; index++)); do
    host="${control_plane_hosts[$index]}"
    ip="${control_plane_ips[$index]}"
    node_name="${host%%.*}"
    if remote "$host" 'test -f /etc/kubernetes/admin.conf'; then
      log "$host is already joined as a control plane"
    else
      remote "$host" \
        "$control_plane_join_command --apiserver-advertise-address '$ip' --node-name '$node_name' --cri-socket unix:///run/containerd/containerd.sock"
    fi
    remote "$primary_control_plane" \
      "KUBECONFIG=/etc/kubernetes/admin.conf kubectl wait --for=condition=Ready 'node/$node_name' --timeout=10m"
  done

  certificate_key=""
  control_plane_join_command=""
fi

log "installing the administrative Helm client on every control plane"
for host in "${control_plane_hosts[@]}"; do
  remote "$host" "HELM_VERSION='$HELM_VERSION' bash '$remote_stage/install-helm.sh'"
done

log "joining Spark worker nodes"
for index in "${!worker_hosts[@]}"; do
  host="${worker_hosts[$index]}"
  node_name="${host%%.*}"
  if remote "$host" 'test -f /etc/kubernetes/kubelet.conf'; then
    log "$host is already joined"
  else
    remote "$host" \
      "$worker_join_command --node-name '$node_name' --cri-socket unix:///run/containerd/containerd.sock"
  fi
done
worker_join_command=""

log "validating and approving kubelet serving certificates"
remote "$primary_control_plane" \
  "KUBECONFIG=/etc/kubernetes/admin.conf INVENTORY_FILE='$remote_stage/inventory.env' bash '$remote_stage/approve-kubelet-serving-csrs.sh'"

log "waiting for all ${#all_hosts[@]} nodes to become Ready"
remote "$primary_control_plane" \
  "KUBECONFIG=/etc/kubernetes/admin.conf bash -c 'source $remote_stage/common.sh; wait_for_nodes ${#all_hosts[@]}'"

if (( control_plane_count > 1 )); then
  log "rebalancing CoreDNS after the HA control planes joined"
  remote "$primary_control_plane" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system rollout restart deployment/coredns"
  remote "$primary_control_plane" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system rollout status deployment/coredns --timeout=5m"
fi

log "copying this repository and protected runtime inventory to every control plane"
archive="$(mktemp)"
tar --exclude=.git -czf "$archive" -C "$repo_root" .
for host in "${control_plane_hosts[@]}"; do
  remote "$host" "install -d -m 0755 '$REMOTE_INSTALL_DIR'"
  remote "$host" "install -d -m 0700 /etc/gemius-k8s"
  scp "${ssh_options[@]}" "$archive" \
    "${REMOTE_USER}@${host}:${remote_stage}/repository.tar.gz"
  remote "$host" \
    "tar -xzf '$remote_stage/repository.tar.gz' -C '$REMOTE_INSTALL_DIR'"
  remote "$host" \
    "install -m 0600 '$remote_stage/inventory.env' /etc/gemius-k8s/inventory.env"
done

log "deploying YuniKorn and both Spark operators"
remote "$primary_control_plane" \
  "cd '$REMOTE_INSTALL_DIR' && KUBECONFIG=/etc/kubernetes/admin.conf PLATFORM_VALUES='$platform_values_rel' ./scripts/install.sh both"

log "applying stable node-role labels"
for host in "${control_plane_hosts[@]}"; do
  node_name="${host%%.*}"
  remote "$primary_control_plane" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node '$node_name' gemius.io/node-role=control-plane --overwrite"
done
for host in "${worker_hosts[@]}"; do
  node_name="${host%%.*}"
  remote "$primary_control_plane" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node '$node_name' gemius.io/node-role=spark-worker --overwrite"
done

log "verifying HA control-plane and etcd membership"
remote "$primary_control_plane" \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system wait --for=condition=Ready pod -l component=etcd --timeout=5m"
observed_control_planes="$(
  remote "$primary_control_plane" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l"
)"
observed_etcd_members="$(
  remote "$primary_control_plane" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get pods -l component=etcd --field-selector=status.phase=Running --no-headers | wc -l"
)"
[[ "$observed_control_planes" -eq "$control_plane_count" ]] || \
  fail "expected $control_plane_count control planes, observed $observed_control_planes"
[[ "$observed_etcd_members" -eq "$control_plane_count" ]] || \
  fail "expected $control_plane_count running etcd members, observed $observed_etcd_members"

log "cluster deployment complete"
remote "$primary_control_plane" \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide"
remote "$primary_control_plane" \
  "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A"
