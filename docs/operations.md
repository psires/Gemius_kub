# Operations and deployment gates

## Pre-production inputs

Before using the platform outside a disposable cluster, provide:

- Kubernetes distribution and exact version;
- total allocatable Spark CPU and memory;
- node pool labels, taints, and autoscaler implementation;
- image registry and object storage endpoints;
- Spark/Python/PEX compatibility matrix;
- group owners, queue ACLs, concurrency limits, and SLAs;
- logging, metrics, event-log storage, and history-server destinations; and
- policy engine or Kubernetes ValidatingAdmissionPolicy availability.

## Acceptance tests

Both operator profiles must run the same representative PEX workloads and pass:

1. Successful driver/executor creation and cleanup.
2. PEX download, digest verification in CI, and Python dependency imports.
3. Dynamic scale-up and scale-down.
4. Queue maximum resources and `maxapplications` under saturation.
5. Idle-capacity borrowing and return when a higher-priority queue becomes busy.
6. Driver, executor, node, scheduler, and operator failure scenarios.
7. Namespace and service-account isolation.
8. Identical application output for Apache and Kubeflow CRDs.

## Capacity changes

Change queue values through a reviewed Git commit and upgrade the
`gemius-spark-platform` Helm release. YuniKorn reloads the `yunikorn-configs`
ConfigMap. Capacity changes affect scheduling and new allocations; they do not
relocate an already running driver.

The group namespaces carry Helm's `resource-policy: keep` annotation. Removing
the platform release therefore does not delete namespaces and all workloads
inside them; namespace removal is a separate, explicitly destructive action.

Keep queue preemption disabled in the initial rollout. After workload recovery
has been proven, delayed executor-oriented preemption can be evaluated. Driver
preemption should remain exceptional.

## Useful commands

```bash
kubectl -n yunikorn port-forward svc/yunikorn-service 9889:9889
kubectl get sparkapplications.spark.apache.org -A
kubectl get sparkapplications.sparkoperator.k8s.io -A
kubectl -n spark-dev get pods -l spark-role=driver
kubectl -n spark-dev get events --sort-by=.lastTimestamp
```

## YuniKorn UI and metrics tunnel for ATM production

The local workstation has no destination credential for the internal nodes;
the usable agent runs on `wc1`. The helper therefore creates two nested SSH
forwards and runs `kubectl port-forward` on an HA control-plane node:

```bash
./scripts/tunnel-yunikorn-atm-prod.sh
```

Keep the command running, then open:

- UI: <http://127.0.0.1:9889/>
- Prometheus metrics: <http://127.0.0.1:9080/ws/v1/metrics>

The default destination is `spark1w4-atm-prod.gem.lan`. If that control-plane
node is unavailable, select another HA member:

```bash
TARGET_HOST=root@spark1w5-atm-prod.gem.lan \
  ./scripts/tunnel-yunikorn-atm-prod.sh
```

The local and jump-box listening ports can also be overridden with
`LOCAL_UI_PORT`, `LOCAL_METRICS_PORT`, `JUMP_UI_PORT`, and
`JUMP_METRICS_PORT`. Every listener binds only to `127.0.0.1`; this tunnel does
not publish the unauthenticated YuniKorn endpoints to the network.
