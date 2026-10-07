#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

require_root
require_command ctr
: "${KUBE_VIP_ADDRESS:?set KUBE_VIP_ADDRESS to the reserved control-plane VIP}"
: "${KUBE_VIP_INTERFACE:=ens3}"
: "${KUBE_VIP_VERSION:?set KUBE_VIP_VERSION}"
: "${KUBE_VIP_KUBECONFIG:=/etc/kubernetes/admin.conf}"

is_ipv4 "$KUBE_VIP_ADDRESS" || fail "invalid kube-vip IPv4 address: $KUBE_VIP_ADDRESS"
[[ "$KUBE_VIP_INTERFACE" =~ ^[A-Za-z0-9._:-]+$ ]] || \
  fail "invalid kube-vip interface: $KUBE_VIP_INTERFACE"
[[ "$KUBE_VIP_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail "invalid kube-vip version: $KUBE_VIP_VERSION"
case "$KUBE_VIP_KUBECONFIG" in
  /etc/kubernetes/admin.conf|/etc/kubernetes/super-admin.conf) ;;
  *) fail "unsupported kube-vip kubeconfig: $KUBE_VIP_KUBECONFIG" ;;
esac
ip link show dev "$KUBE_VIP_INTERFACE" >/dev/null 2>&1 || \
  fail "kube-vip interface does not exist: $KUBE_VIP_INTERFACE"

image="ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}"
manifest_dir=/etc/kubernetes/manifests
manifest_path="$manifest_dir/kube-vip.yaml"
manifest_tmp="$(mktemp)"
container_id="kube-vip-manifest-${RANDOM}-$$"
trap 'rm -f "$manifest_tmp"' EXIT

log "pulling $image"
ctr --namespace k8s.io images pull "$image"
log "generating kube-vip manifest for $KUBE_VIP_ADDRESS on $KUBE_VIP_INTERFACE"
ctr --namespace k8s.io run --rm --net-host "$image" "$container_id" /kube-vip \
  manifest pod \
  --interface "$KUBE_VIP_INTERFACE" \
  --address "$KUBE_VIP_ADDRESS" \
  --controlplane \
  --arp \
  --leaderElection \
  --k8sConfigPath "$KUBE_VIP_KUBECONFIG" >"$manifest_tmp"

grep -q '^kind: Pod$' "$manifest_tmp" || fail "generated kube-vip manifest is not a Pod"
grep -q 'name: kube-vip' "$manifest_tmp" || fail "generated manifest lacks kube-vip container"
grep -Fq "value: $KUBE_VIP_ADDRESS" "$manifest_tmp" || \
  fail "generated manifest lacks the requested VIP"
grep -Fq "path: $KUBE_VIP_KUBECONFIG" "$manifest_tmp" || \
  fail "generated manifest lacks the requested kubeconfig mount"

install -d -m 0755 "$manifest_dir"
if [[ -f "$manifest_path" ]] && cmp -s "$manifest_tmp" "$manifest_path"; then
  log "kube-vip manifest is already current"
else
  install -m 0600 "$manifest_tmp" "$manifest_path"
  log "installed kube-vip static-pod manifest"
fi
