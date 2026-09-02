# Architecture

## Fixed decisions

- A single elastic Kubernetes compute pool serves all four groups.
- Groups are namespaces and YuniKorn queues, not dedicated Spark clusters.
- Apache and Kubeflow operators may run simultaneously.
- Applications use native Spark-on-Kubernetes cluster mode.
- YuniKorn is the primary capacity, ordering, and concurrency authority.
- Kubernetes RBAC remains the security boundary.

## Operator boundary

The `gemius-spark-job` chart is the compatibility boundary. End users select
`operator: apache` or `operator: kubeflow`; common values are translated into
the corresponding CRD.

Operator-specific capabilities that do not have safe parity are deliberately
not hidden. For example, Kubeflow `ScheduledSparkApplication` and Apache
`SparkCluster` are outside the common job chart and must be introduced through
an architecture decision record if needed.

## Scheduling

The queues are children of `root`:

```text
root
├── spark-prod
├── spark-beta
├── spark-dev
└── spark-adhoc
```

Each leaf queue has:

- a guaranteed CPU and memory allocation;
- a maximum CPU and memory allocation;
- a maximum number of running applications;
- a priority offset; and
- fair application sorting.

Unused guaranteed resources remain available to another queue until demand
returns. Running applications are not moved between namespaces. New executor
allocations follow the latest queue configuration, while dynamic allocation
allows applications to return unused executors.

A namespace placement rule assigns `spark-<group>` to `root.spark-<group>`.
This mapping takes queue selection out of end-user control; Kubernetes RBAC
controls which group namespace a user may submit to.

The committed capacity is an illustrative 100-vCPU/400-GiB Spark pool. Change
`charts/gemius-spark-platform/values.yaml` or supply an environment values file
before deployment. The initial four-VM cluster supplies
`deploy/values/cluster-4vm.yaml` through the `PLATFORM_VALUES` installer
variable.

## Coexistence

The operators own distinct API groups:

| Operator | API | Fully qualified resource |
|---|---|---|
| Apache | `spark.apache.org/v1` | `sparkapplications.spark.apache.org` |
| Kubeflow | `sparkoperator.k8s.io/v1beta2` | `sparkapplications.sparkoperator.k8s.io` |

Their `sparkapp` short names collide in Kubernetes discovery. Automation must
therefore use the fully qualified resource names.

Both operators watch `spark-prod`, `spark-beta`, `spark-dev`, and
`spark-adhoc`. Drivers use the common `spark` service account in their own
namespace.

## Security model

- A namespace-scoped Role permits a Spark driver to manage executor pods,
  services, ConfigMaps, PVCs, and events only in its namespace.
- End users should receive permission to create only the selected operator's
  SparkApplication CRD in their group namespace.
- Namespace-to-queue placement is enforced by YuniKorn. A later validating
  admission policy should additionally enforce per-application resource
  envelopes and reserved labels.
- Data-store credentials should use workload identity when available.
- NetworkPolicy is intentionally not default-deny in this first portable
  baseline because required data endpoints are not known yet.

## Version policy

Platform versions are pinned in `versions.env`. Spark, Python, Java, Hadoop
connectors, PEX build targets, and the application image must be tested as one
compatibility set. Do not upgrade only the driver image in production.
