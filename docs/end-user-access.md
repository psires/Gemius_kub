# End-user Kubernetes access

End-user kubeconfigs authenticate directly to the HA Kubernetes API endpoint at
`https://10.21.2.139:6443`. They are private credentials and must be stored
under `private/`, which is excluded from version control.

The Kubernetes username for Jakub Partyka is `jakub.partyka`. His certificate
is bound to the `gemius-spark-end-user` ClusterRole separately in each Spark
application namespace:

- `spark-prod`
- `spark-beta`
- `spark-dev`
- `spark-adhoc`

The role permits job submission and lifecycle operations through both installed
Spark operator APIs, along with access to job pods, logs, port forwarding,
ConfigMaps, services, and persistent volume claims. It deliberately excludes
secrets, RBAC administration, Kubernetes system namespaces, and cluster-level
administration.

Select a namespace without changing credentials:

```bash
kubectl --kubeconfig client.conf config set-context --current --namespace spark-dev
```

Verify the credential and permissions:

```bash
kubectl --kubeconfig client.conf auth whoami
kubectl --kubeconfig client.conf auth can-i create sparkapplications.spark.apache.org -n spark-dev
kubectl --kubeconfig client.conf auth can-i create sparkapplications.sparkoperator.k8s.io -n spark-prod
kubectl --kubeconfig client.conf auth can-i get secrets -n spark-dev
```

The final command must return `no`.
