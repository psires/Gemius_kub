# Monitoring and visualization options

## Current state

The initial cluster exposes useful telemetry but has no collector, time-series
database, or shared visualization layer yet. The endpoints below are internal
Kubernetes Service or pod-network ports. They are not host-network listeners
and therefore do not appear in `ss` or `netstat` on every node.

| Component | Available endpoint |
| --- | --- |
| YuniKorn scheduler | Prometheus metrics on service port 9080 at `/ws/v1/metrics` |
| YuniKorn web UI | Service port 9889 |
| Apache Spark operator | Metrics container port 19090; its HTTP path needs explicit chart configuration because `/metrics` currently returns 404 |
| Kubeflow Spark operator | Controller and webhook metrics on port 8080 at `/metrics` |
| Calico | Controller metrics service on port 9094 |
| CoreDNS | Metrics on service port 9153 |

The cluster does not currently have:

- Metrics Server or the `metrics.k8s.io` API (`kubectl top` is unavailable);
- Prometheus Operator CRDs such as `ServiceMonitor` and `PodMonitor`;
- a StorageClass, PV, or PVC;
- an IngressClass, Ingress, or LoadBalancer service; or
- persistent Spark event logs and a Spark History Server.

## Options

### 1. Live-state UI only

Install Metrics Server and use Headlamp plus the existing YuniKorn UI. Access
them through SSH and `kubectl port-forward`.

This is low-cost and quickly answers “what is running now?”, including pod
state, events, logs, resource YAML, queue state, and live CPU/memory. It has no
historical trends, durable alerts, capacity forecasting, or cross-job Spark
analysis.

Headlamp is preferred over Kubernetes Dashboard. Dashboard was archived in
2026, while Headlamp is an official Kubernetes subproject, respects Kubernetes
RBAC, supports desktop and in-cluster operation, and can later use OIDC.

### 2. Kubernetes and scheduler metrics (recommended baseline)

Install:

- Metrics Server for `kubectl top`, Headlamp resource graphs, and future HPA;
- `kube-prometheus-stack` for Prometheus Operator, Prometheus, Alertmanager,
  Grafana, kube-state-metrics, node-exporter, dashboards, and alert rules;
- explicit `ServiceMonitor`/`PodMonitor` resources for YuniKorn, both Spark
  operators, Calico, and CoreDNS; and
- Headlamp for interactive resource exploration.

This provides current state, historical resource usage, queue behavior,
operator health, alerting, and a shared Grafana view. It does not by itself
preserve Spark stage/task UIs after applications finish or centralize logs.

### 3. Full self-hosted observability

Extend option 2 with:

- Grafana Loki for log storage;
- Grafana Alloy as the per-node Kubernetes log collector;
- Spark History Server backed by durable shared event-log storage; and
- optional Tempo/OpenTelemetry later if the applications emit traces.

This gives correlated metrics and logs plus completed-job analysis. Spark logs
can be extremely large, so retention, label cardinality, and object storage
must be designed before enabling this cluster-wide. Loki itself has no built-in
authentication and must remain behind an authenticated proxy.

### 4. External or managed observability

Run only collectors in this cluster and remote-write metrics/logs to an
existing Prometheus-compatible, Grafana, Elastic, or managed platform. This is
the strongest option for durable history across a control-plane or cluster
loss, but introduces recurring cost, data-egress/security review, and external
service dependency.

## Recommended architecture

```text
Kubernetes API --------------------------> Headlamp
                                              |
nodes / kubelets / kube-state-metrics         | current objects, events, logs
YuniKorn / Spark operators / Calico / DNS     |
                 |                            |
                 +--> Prometheus --> Grafana--+
                          |
                          +--> Alertmanager

pod and node logs --> Alloy --> Loki -------> Grafana       (phase 2)
Spark event logs --> shared storage --> History Server       (phase 2)
```

Grafana is the operations and trend dashboard. Headlamp is the Kubernetes
object explorer. YuniKorn UI is the authoritative queue/application view.
Spark driver UI is used while an application is running, and Spark History
Server reconstructs job/stage/task views after completion.

## Initial persistence and access

For this four-node, single-control-plane stage, use a static local PV on an SSD
for Prometheus, with node affinity and documented recovery limitations. A
100–200 GiB volume, 15–30 day time retention, and an 80–85% size ceiling are a
reasonable starting point. Prometheus recommends a local filesystem and does
not support NFS for its TSDB. The local PV is not replicated; use snapshots or
remote write when monitoring history must survive a node loss.

Do not expose Grafana, Prometheus, Alertmanager, Headlamp, YuniKorn, or Spark UI
with unauthenticated NodePorts. Initially use a port-forward on worker-09 plus
an SSH tunnel through `wc1`. Later add an ingress controller, internal DNS,
TLS, and OIDC. Headlamp must use per-user RBAC rather than a shared
cluster-admin token. The YuniKorn UI and Spark UIs also need an authenticating
reverse proxy before shared browser access.

For example, the current YuniKorn `ClusterIP` is `10.102.5.208`. From a cluster
node, its UI is reachable on `10.102.5.208:9889` and its Prometheus endpoint on
`10.102.5.208:9080/ws/v1/metrics`, even though those ports are not listening on
the node itself. Service IPs can change if the Service is recreated, so
automation should resolve `yunikorn-service.yunikorn.svc` or use `kubectl
port-forward`, rather than permanently embedding this IP.

## Dashboards

The first Grafana release should provision dashboards from Git rather than
requiring manual imports:

1. **Cluster overview:** node readiness, CPU/memory, filesystem pressure,
   pod count/restarts, pending pods, API latency, and network errors.
2. **Spark capacity:** worker allocatable/requested/used resources, executor
   counts, and CPU/memory headroom.
3. **YuniKorn queues:** guarantee, maximum, allocation, pending demand,
   applications, and queue saturation for prod/beta/dev/adhoc.
4. **Spark applications:** submitted/running/succeeded/failed by operator,
   namespace, duration, start latency, and executor failures.
5. **Control components:** Apache operator reconciliation, Kubeflow controller
   and webhook, YuniKorn health, Calico, CoreDNS, Prometheus scrape health.

Keep `applicationId`, pod UID, executor ID, stage ID, and task ID out of broad
metric labels unless there is a bounded retention/use case; those dimensions
can create costly time-series cardinality.

## Alerts

Start with actionable alerts:

- node NotReady, memory/disk/PID pressure, or filesystem below 15% free;
- Kubernetes API, CoreDNS, Calico, YuniKorn, or an operator target down;
- operator/webhook crash loops or reconciliation errors;
- Spark application failure rate and start latency;
- YuniKorn pending demand, application-limit saturation, or queue maximum
  saturation; and
- Prometheus target/scrape failure, TSDB disk pressure, and Alertmanager health.

Alert routing (email, Slack, PagerDuty, or another system) is a separate
required decision. Alerts without an owned route and runbook should not page.

## Spark-specific work

Operator health metrics are not application performance metrics. Add a common
monitoring section to `gemius-spark-job` so both operator renderers can enable
driver/executor metrics consistently. The Spark image must include a compatible
JMX Prometheus exporter if that path is chosen. Spark's built-in Prometheus
servlet is another option, but it is documented as experimental.

Enable event logging for every application and deploy one Spark History Server
after selecting a shared event-log store. Object storage or HDFS is preferable
for durable history. A local `hostPath` is not suitable because drivers can run
on any worker and a History Server on another node cannot see those files.

## Deployment sequence

1. Pin chart/image versions and decide retention, local-PV path, backup, and
   alert destinations.
2. Install Metrics Server and verify `kubectl top nodes` without disabling
   kubelet TLS verification; the cluster already uses CA-signed kubelet serving
   certificates.
3. Install `kube-prometheus-stack` with a local SSD-backed Prometheus PV and
   Git-provisioned dashboards/rules.
4. Add and test monitors for YuniKorn, Kubeflow, Apache operator, Calico, and
   CoreDNS. Resolve the Apache operator metrics path before declaring it a
   healthy target.
5. Provide SSH-tunnel helper scripts for Grafana and YuniKorn; trial Headlamp
   as a desktop client first.
6. Add common Spark driver/executor metrics to both job renderers and test them
   with one real PEX workload.
7. Select Spark event-log storage and deploy Spark History Server.
8. Add Loki and Alloy only after log volume/retention sizing; then add ingress,
   TLS, and OIDC for shared access.

## Recommendation

Proceed with option 2 first. It has the best operational value-to-complexity
ratio and uses endpoints already present in the cluster. Design the manifests
so Loki/Alloy and Spark History Server can be enabled independently in phase 2.
Do not start with a full tracing stack or unauthenticated browser endpoints.

## Primary references

- [Prometheus Operator installation](https://prometheus-operator.dev/docs/getting-started/installation/)
- [Metrics Server](https://kubernetes-sigs.github.io/metrics-server/)
- [Headlamp installation and authentication](https://headlamp.dev/docs/latest/installation/)
- [YuniKorn scheduler metrics](https://yunikorn.apache.org/docs/next/performance/metrics/)
- [Spark monitoring and History Server](https://spark.apache.org/docs/latest/monitoring)
- [Prometheus storage requirements](https://prometheus.io/docs/prometheus/latest/storage/)
- [Loki and Alloy installation](https://grafana.com/docs/loki/latest/setup/install/)
