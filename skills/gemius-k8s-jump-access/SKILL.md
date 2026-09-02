---
name: gemius-k8s-jump-access
description: Access the Gemius Spark Kubernetes hosts through the wc1 jump box for SSH, kubectl, Helm, deployment, diagnostics, and node administration. Use only for the spark-dev-02 worker-09 through worker-12 environment.
---

# Gemius Kubernetes jump-box access

Use this route whenever a task requires access to the Gemius Spark Kubernetes
VMs. The worker hosts are not directly reachable from the local machine.

## Connection invariant

Connect from the local machine to `root@wc1.gem.lan`, then use the SSH agent
that is already running on `wc1`:

```bash
export SSH_AUTH_SOCK=/tmp/ssh-x6DjE2qGUQhc/agent.2816
ssh root@<target>
```

Before relying on that socket, verify it on `wc1`:

```bash
test -S /tmp/ssh-x6DjE2qGUQhc/agent.2816
SSH_AUTH_SOCK=/tmp/ssh-x6DjE2qGUQhc/agent.2816 ssh-add -l
```

The socket belongs to a running agent and can disappear after logout, reboot,
or session replacement. If either check fails, do not search for or guess a
different agent socket. Ask the user for its current path. Never copy or expose
private key material.

For a non-interactive command from the local machine, use the equivalent
nested connection:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=15 root@wc1.gem.lan \
  "SSH_AUTH_SOCK=/tmp/ssh-x6DjE2qGUQhc/agent.2816 \
   ssh -o BatchMode=yes root@<target> '<command>'"
```

Keep strict host-key checking enabled. Use the caller's trusted known-hosts
configuration; do not silently accept a changed host key.

## Inventory

| Role | SSH target | Node name | Address |
| --- | --- | --- | --- |
| Control plane | `spark-dev-02-worker-09.archeo.gem.lan` | `spark-dev-02-worker-09` | `10.21.3.234` |
| Spark worker | `spark-dev-02-worker-10.archeo.gem.lan` | `spark-dev-02-worker-10` | `10.21.3.235` |
| Spark worker | `spark-dev-02-worker-11.archeo.gem.lan` | `spark-dev-02-worker-11` | `10.21.3.237` |
| Spark worker | `spark-dev-02-worker-12.archeo.gem.lan` | `spark-dev-02-worker-12` | `10.21.3.238` |

Run cluster-wide `kubectl` and Helm commands on worker-09 with:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

The deployed repository is normally available at `/opt/gemius-kub` on
worker-09. Confirm it and its revision before using it; do not assume it is
synchronized with the caller's working tree.

## File transfer

For files that must reach a target host, copy them to a uniquely named path
under `/tmp` on `wc1`, then run the second `scp` from `wc1` with the agent socket
set. Do not attempt a direct local-to-worker transfer.

Prefer rendering or packaging artifacts locally, validating them, and then
transferring the exact artifact that will be applied. Remove only temporary
files created by the current task, and only when their exact paths are known.

## Operational guardrails

- Start with read-only discovery: node health, workload state, events, current
  configuration, and the exact target resource.
- Distinguish worker-09's single-control-plane role from the three Spark worker
  nodes. Do not schedule compute on worker-09 unless the user explicitly asks
  to relax its control-plane isolation.
- Treat SSH reachability as access, not authorization. Obtain any approval
  required by the active environment immediately before external mutations.
- Preserve running workloads and unrelated host processes unless the user has
  explicitly placed them in scope.
- Do not run `kubeadm reset`, remove `/var/lib/etcd`, wipe container or kubelet
  storage, reformat disks, or replace the cluster unless the user explicitly
  requests that destructive operation and the exact recovery implications have
  been explained.
- For Kubernetes changes, perform client-side validation when available, then
  `kubectl apply --dry-run=server` before the live apply. Afterward, verify the
  resulting resources, events, scheduler assignment, and application output.
- Use fully qualified SparkApplication resource names because both installed
  operators use the `sparkapp` short name:
  `sparkapplications.spark.apache.org` and
  `sparkapplications.sparkoperator.k8s.io`.

This skill supplies routing and environment context only. It does not authorize
a deployment, restart, deletion, package installation, firewall change, or any
other mutation not already requested by the user.
