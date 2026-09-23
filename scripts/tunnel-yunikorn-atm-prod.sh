#!/usr/bin/env bash
set -euo pipefail

JUMP_HOST="${JUMP_HOST:-root@wc1}"
TARGET_HOST_OVERRIDE="${TARGET_HOST:-}"
JUMP_AGENT_SOCKET="${JUMP_AGENT_SOCKET:-/tmp/ssh-x6DjE2qGUQhc/agent.2816}"
LOCAL_UI_PORT="${LOCAL_UI_PORT:-9889}"
LOCAL_METRICS_PORT="${LOCAL_METRICS_PORT:-9080}"
JUMP_UI_PORT="${JUMP_UI_PORT:-29889}"
JUMP_METRICS_PORT="${JUMP_METRICS_PORT:-29080}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_ssh_target() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] || \
    fail "invalid SSH target: $value"
}

validate_port() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be a numeric TCP port"
  (( 10#$value >= 1 && 10#$value <= 65535 )) || \
    fail "$name must be between 1 and 65535"
}

command -v ssh >/dev/null 2>&1 || fail "ssh is required"
validate_ssh_target "$JUMP_HOST"
if [[ -n "$TARGET_HOST_OVERRIDE" ]]; then
  validate_ssh_target "$TARGET_HOST_OVERRIDE"
  control_plane_candidates=("$TARGET_HOST_OVERRIDE")
else
  control_plane_candidates=(
    root@spark1w4-atm-prod.gem.lan
    root@spark1w5-atm-prod.gem.lan
    root@spark1w6-atm-prod.gem.lan
  )
fi
[[ "$JUMP_AGENT_SOCKET" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
  fail "invalid jump-box agent socket path"
validate_port LOCAL_UI_PORT "$LOCAL_UI_PORT"
validate_port LOCAL_METRICS_PORT "$LOCAL_METRICS_PORT"
validate_port JUMP_UI_PORT "$JUMP_UI_PORT"
validate_port JUMP_METRICS_PORT "$JUMP_METRICS_PORT"
[[ "$LOCAL_UI_PORT" != "$LOCAL_METRICS_PORT" ]] || \
  fail "local UI and metrics ports must differ"
[[ "$JUMP_UI_PORT" != "$JUMP_METRICS_PORT" ]] || \
  fail "jump-box UI and metrics ports must differ"

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=yes
)

printf 'Verifying the SSH agent on %s...\n' "$JUMP_HOST"
ssh "${ssh_options[@]}" "$JUMP_HOST" \
  "test -S '$JUMP_AGENT_SOCKET' && SSH_AUTH_SOCK='$JUMP_AGENT_SOCKET' ssh-add -l >/dev/null" || \
  fail "the configured SSH agent is unavailable on $JUMP_HOST"

target_host=""
target_probe='command -v kubectl >/dev/null 2>&1 && test -r /etc/kubernetes/admin.conf && KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n yunikorn get service yunikorn-service >/dev/null 2>&1'
for candidate in "${control_plane_candidates[@]}"; do
  printf 'Checking YuniKorn access through %s... ' "$candidate"
  printf -v probe_command \
    'export SSH_AUTH_SOCK=%q; exec ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o CheckHostIP=no %q %q' \
    "$JUMP_AGENT_SOCKET" "$candidate" "$target_probe"
  if ssh "${ssh_options[@]}" "$JUMP_HOST" "$probe_command"; then
    target_host="$candidate"
    printf 'ready\n'
    break
  fi
  printf 'unavailable\n'
done

[[ -n "$target_host" ]] || \
  fail "no usable ATM production control plane was found; deploy the cluster and YuniKorn first, or set TARGET_HOST to a working control plane"

printf 'YuniKorn UI:      http://127.0.0.1:%s/\n' "$LOCAL_UI_PORT"
printf 'YuniKorn metrics: http://127.0.0.1:%s/ws/v1/metrics\n' "$LOCAL_METRICS_PORT"
printf 'Keep this process running; press Ctrl-C to close both tunnel hops.\n'

printf -v second_hop \
  'export SSH_AUTH_SOCK=%q; exec ssh -o BatchMode=yes -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes -o CheckHostIP=no -L 127.0.0.1:%q:127.0.0.1:9889 -L 127.0.0.1:%q:127.0.0.1:9080 %q %q' \
  "$JUMP_AGENT_SOCKET" \
  "$JUMP_UI_PORT" \
  "$JUMP_METRICS_PORT" \
  "$target_host" \
  'KUBECONFIG=/etc/kubernetes/admin.conf exec kubectl -n yunikorn port-forward --address 127.0.0.1 svc/yunikorn-service 9889:9889 9080:9080'

exec ssh "${ssh_options[@]}" \
  -L "127.0.0.1:${LOCAL_UI_PORT}:127.0.0.1:${JUMP_UI_PORT}" \
  -L "127.0.0.1:${LOCAL_METRICS_PORT}:127.0.0.1:${JUMP_METRICS_PORT}" \
  "$JUMP_HOST" "$second_hop"
