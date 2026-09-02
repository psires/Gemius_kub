# Four-node kubeadm cluster

## Topology

| Role | Host | Address |
| --- | --- | --- |
| Control plane | `spark-dev-02-worker-09.archeo.gem.lan` | `10.21.3.234` |
| Worker | `spark-dev-02-worker-10.archeo.gem.lan` | `10.21.3.235` |
| Worker | `spark-dev-02-worker-11.archeo.gem.lan` | `10.21.3.237` |
| Worker | `spark-dev-02-worker-12.archeo.gem.lan` | `10.21.3.238` |

This is an initial, non-HA control plane. The loss of worker-09 stops API and
scheduling operations, although already-running pods can continue on workers.
Before production, add an API load-balancer endpoint and two more control-plane
members, or migrate the control plane to dedicated machines.

## Software and networking

- Ubuntu 24.04 hosts
- Kubernetes 1.35 packages from `pkgs.k8s.io`
- containerd with the systemd cgroup driver
- Calico 3.32.2 using VXLAN and `192.168.0.0/16` pod addresses
- Kubernetes services on `10.96.0.0/12`
- Helm 3.19.0 on the control-plane host

The hosts' general APT proxy rejects `pkgs.k8s.io`, although direct HTTPS to
the repository and its CDN is available. The node script installs narrowly
scoped APT `DIRECT` rules for those two signed-repository hostnames; all other
APT traffic continues to use the existing proxy configuration.

The pod and service ranges do not overlap the observed `10.21.0.0/21` host
network. Calico VXLAN requires bidirectional UDP 4789 between nodes. The
kubeadm control-plane and worker ports documented by Kubernetes must also be
open if an upstream firewall is introduced. UFW is currently inactive.

## Storage placement

The root volume is only 40 GB, so bootstrap deliberately moves the two large
runtime consumers:

- `/mnt/ssd1/containerd`: pulled images and writable container layers
- `/mnt/ssd2/kubelet`: pod volumes, logs managed below the kubelet root, and
  disk-backed `emptyDir` data used by Spark

The automation verifies both paths are mounted as ext4 before changing a node.
It does not format disks and does not edit the existing MooseFS mount entries.

The deployment uses `deploy/values/cluster-4vm.yaml` instead of the generic
100-vCPU example. It caps all Spark queues together at 22 vCPU and 84 GiB on
the 24-vCPU/approximately-94-GiB worker pool. Queue guarantees total 20 vCPU
and 74 GiB. Each queue's maximum is higher than its guarantee, so idle capacity
can still move between all four groups without exceeding the shared ceiling.

During initial deployment, pre-existing host Java processes were still active,
so the live cluster was left on
`deploy/values/cluster-4vm-temporary-coexistence.yaml` (18 vCPU/38 GiB root
maximum). After those processes stop, activate the normal profile from
worker-09:

```bash
cd /opt/gemius-kub
KUBECONFIG=/etc/kubernetes/admin.conf \
  PLATFORM_VALUES=deploy/values/cluster-4vm.yaml ./scripts/install.sh both
```

## Run from the jump host

Copy or clone this repository to `wc1`, then run:

```bash
cd /path/to/Gemius_kub
SSH_AUTH_SOCK=/tmp/ssh-x6DjE2qGUQhc/agent.2816 \
  ./infra/kubeadm/orchestrate.sh
```

The orchestration is safe to rerun for the cluster it created: package and
Helm operations are convergent, initialized/joined nodes are detected, and
Helm uses upgrades. It intentionally contains no reset or disk-format path.

Kubelets request CA-signed serving certificates. Kubernetes intentionally does
not auto-approve those requests, so the bootstrap calls
`approve-kubelet-serving-csrs.sh`. That script approves only requests whose
requestor, organization, DNS SAN, and IP SAN match the explicit inventory.
Rerun it after a legitimate serving-certificate rotation; it fails closed for
unknown nodes or addresses.

## Verify

On worker-09:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get nodes -o wide
kubectl get pods -A
kubectl get sparkapplications.spark.apache.org -A
kubectl get sparkapplications.sparkoperator.k8s.io -A
helm list -A
```

Do not submit the checked-in example jobs unchanged: their container image and
PEX URIs are placeholders. Configure an internal registry/artifact location
reachable from every node first.
