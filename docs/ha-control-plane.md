# Parameterized HA control plane

`infra/kubeadm/orchestrate.sh` deploys an inventory with an explicit number of
stacked kubeadm control-plane/etcd nodes. The requested count is supplied with
`--control-planes N`.

## Topology contract

- `N` must be a positive odd number. Use `1` for a non-HA development cluster,
  `3` to tolerate one control-plane failure, or `5` to tolerate two.
- The first `N` entries in `NODE_HOSTS` and `NODE_IPS` become control-plane and
  stacked etcd members. All remaining entries become Spark workers.
- At least one Spark worker must remain after selecting the control planes.
- IPv4 node addresses are currently required.
- For `N > 1`, `CONTROL_PLANE_ENDPOINT` must be a stable TCP load-balancer or
  floating virtual-IP endpoint. It must not be an individual node address.

The deployment script deliberately does not create the load balancer. Before
bootstrap, configure its listener and health checks on TCP port 6443 and add
all intended control-plane addresses as backends. A DNS endpoint must resolve
from every node. A virtual IP must be reachable from every node. The script
stops after initializing the first member if the generated kubeconfig cannot
reach the Kubernetes `/readyz` endpoint through this shared address.

Every listed VM must also satisfy the existing node contract: root SSH access
from the orchestration host, stable forward and reverse naming, and mounted
ext4 filesystems at `/mnt/ssd1` and `/mnt/ssd2`. The network must permit the
kubeadm control-plane ports, including TCP 2379-2380 between stacked etcd
members, and Calico VXLAN traffic on UDP 4789 between all nodes.

## Prepare an inventory

Copy `infra/kubeadm/inventory-ha.example.env` and replace every example host,
address, and endpoint. The arrays must stay aligned and ordered:

```bash
cp infra/kubeadm/inventory-ha.example.env /secure/path/new-cluster.env
```

Create a YuniKorn platform values file sized for the worker pool. Queue
guarantees must fit within the shared root guarantee, and the root maximum must
leave capacity for Kubernetes and platform services.

## Validate without connecting

The plan operation validates the count, inventory, endpoint shape, duplicate
hosts and addresses, and platform-values path. It performs no SSH connection
and changes nothing:

```bash
./infra/kubeadm/orchestrate.sh \
  --control-planes 3 \
  --inventory /secure/path/new-cluster.env \
  --platform-values deploy/values/new-cluster.yaml \
  --plan
```

Review the printed role assignment carefully. Changing `N` changes which
ordered inventory entries receive control-plane state.

## Deploy from the jump host

Run the same command without `--plan` on a host that can SSH to every listed
machine. For the Gemius environment, that is normally `wc1` with its current
agent socket:

```bash
SSH_AUTH_SOCK=/path/to/current/agent.socket \
  ./infra/kubeadm/orchestrate.sh \
    --control-planes 3 \
    --inventory /secure/path/new-cluster.env \
    --platform-values deploy/values/new-cluster.yaml
```

The automation:

1. Validates every target and refuses conflicting existing cluster roles.
2. Prepares containerd, kubelet, kubeadm, and node storage.
3. Initializes the first control plane against the shared endpoint.
4. Installs Calico and verifies the API through the shared endpoint.
5. Uploads kubeadm's short-lived encrypted certificate bundle and joins the
   other control planes sequentially.
6. Joins the Spark workers, validates kubelet serving CSRs, and waits for all
   nodes.
7. Restarts CoreDNS after HA membership is established.
8. Installs Helm, the repository, and a mode-0600 runtime inventory on every
   control plane so administration does not depend on the first member.
9. Deploys YuniKorn and both Spark operators once, labels node roles, and
   verifies that the observed control-plane and running etcd counts both equal
   `N`.

The uploaded-certificate decryption key is kept in a shell variable, passed to
each sequential `kubeadm join`, never printed or persisted by the script, and
cleared after the control-plane joins. Like any command-line secret, it can be
seen transiently by privileged process inspection during a join. kubeadm's
uploaded certificate Secret and key expire after two hours.

The selected inventory is installed as `/etc/gemius-k8s/inventory.env` on each
control plane for later CSR validation and recovery operations. It is readable
only by root. Each control plane also receives `/opt/gemius-kub` and Helm, but
only the first member performs the initial Helm deployments.

## Failure tolerance and boundaries

A healthy stacked topology requires a majority of etcd members. An odd-sized
cluster tolerates `(N - 1) / 2` simultaneous control-plane failures. This does
not by itself make every platform component highly available: YuniKorn, Spark
operators, DNS placement, monitoring, storage, and individual Spark drivers
need their own replica and recovery designs.

The script supports convergent reruns for the same inventory, `N`, cluster
name, and shared endpoint. It refuses automatic promotion of an existing
worker, demotion of an existing control plane, or attachment to a different
cluster. Those are migration operations and need a separate reviewed plan.
