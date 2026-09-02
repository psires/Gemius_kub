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

## Install

Install the shared scheduler, queues, namespaces, and both operators:

```bash
./scripts/install.sh both
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

## Observe applications

Both CRDs use the `sparkapp` short name, so use fully qualified resource names
when both operators are installed:

```bash
kubectl get sparkapplications.spark.apache.org -A
kubectl get sparkapplications.sparkoperator.k8s.io -A
```

See [architecture](docs/architecture.md), [PEX contract](docs/pex.md), and
[operations](docs/operations.md) for the design and production gates.
