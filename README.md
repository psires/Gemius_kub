# Gemius Spark on Kubernetes

This repository deploys one shared Spark compute platform with four logical
groups (`prod`, `beta`, `dev`, and `adhoc`) and lets each workload choose one
of two Spark operators:

- `apache`: Apache Spark Kubernetes Operator (`spark.apache.org/v1`)
- `kubeflow`: Kubeflow Spark Operator (`sparkoperator.k8s.io/v1beta2`)

Both operators use the same namespaces, service accounts, PEX convention, and
Apache YuniKorn queues. They can be installed together in one cluster.

## Architecture

```text
PEX artifact + job values
          |
          v
gemius-spark-job Helm chart -- operator=apache|kubeflow
          |
          +--> Apache SparkApplication -----+
          |                                  |
          +--> Kubeflow SparkApplication ----+--> YuniKorn --> shared nodes
                                                 | prod
                                                 | beta
                                                 | dev
                                                 ` adhoc
```

There are no group-specific Spark masters or worker pools. Queue guarantees
and limits control how the shared capacity moves between groups.

## Prerequisites

- A Kubernetes version in the supported intersection of all pinned components;
  the Apache operator chart currently requires Kubernetes 1.34 or newer
- Helm 3
- `kubectl` configured for the target cluster
- A Spark Python image containing `pex_runner.py`
- PEX artifacts reachable through a URI supported by the Spark image

Review and replace all example capacity and artifact values before production.

## Bootstrap the four-node cluster

The checked-in kubeadm automation builds the initial cluster with worker-09 as
the control plane and worker-10 through worker-12 as workers. Run it on the
jump host, where the existing SSH agent can reach all four nodes:

```bash
cd /path/to/Gemius_kub
SSH_AUTH_SOCK=/tmp/ssh-x6DjE2qGUQhc/agent.2816 \
  ./infra/kubeadm/orchestrate.sh --control-planes 1
```

The automation installs Kubernetes 1.35, containerd, Calico, Helm, and then
deploys YuniKorn plus both Spark operators. It refuses to replace an existing
cluster and does not modify the existing MooseFS mounts. See
[the kubeadm runbook](docs/kubeadm-cluster.md) for topology, storage, reruns,
and verification.

For a new HA cluster, supply an ordered inventory, an odd control-plane count,
and a stable API load-balancer endpoint. Validate the role assignment without
connecting first:

```bash
./infra/kubeadm/orchestrate.sh \
  --control-planes 3 \
  --inventory /secure/path/new-cluster.env \
  --platform-values deploy/values/new-cluster.yaml \
  --plan
```

See [the HA control-plane runbook](docs/ha-control-plane.md) before removing
`--plan`.

## Install

Install the shared scheduler, queues, namespaces, and both operators:

```bash
./scripts/install.sh both
```

For the initial four-VM cluster, use its capacity profile:

```bash
PLATFORM_VALUES=deploy/values/cluster-4vm.yaml ./scripts/install.sh both
```

Install only one operator profile:

```bash
./scripts/install.sh apache
./scripts/install.sh kubeflow
```

The component versions are pinned in `versions.env`.

## Render or submit a job

The same chart and nearly identical values are used for both operators:

```bash
./scripts/render-job.sh apache examples/jobs/apache-dev.yaml
./scripts/render-job.sh kubeflow examples/jobs/kubeflow-dev.yaml
```

After reviewing the rendered manifest, submit it with Helm:

```bash
helm upgrade --install example-apache ./charts/gemius-spark-job \
  --namespace spark-dev \
  --values examples/jobs/apache-dev.yaml \
  --set operator=apache
```

Replace the example image, PEX URI, and entrypoint first.

## Run the all-worker Spark Pi validation

Submit a parameterized Pi calculation through the Apache operator by passing
the required number of decimal places:

```bash
./scripts/submit-spark-pi.sh 7
```

The checked-in Spark Pi validation uses the Apache operator and the dev queue.
It places one executor on each of the three Spark worker nodes and verifies a
deterministic value of Pi to seven decimal places:

```bash
kubectl apply -k examples/spark-pi
```

See [the Spark Pi example](examples/spark-pi/README.md) for validation and
cleanup commands.

## Observe applications

Both CRDs use the `sparkapp` short name, so use fully qualified resource names
when both operators are installed:

```bash
kubectl get sparkapplications.spark.apache.org -A
kubectl get sparkapplications.sparkoperator.k8s.io -A
```

See [architecture](docs/architecture.md), [PEX contract](docs/pex.md), and
[operations](docs/operations.md) for the design and production gates. The
[monitoring options](docs/monitoring-options.md) document covers metrics,
dashboards, logs, Spark history, access, and the recommended rollout.
