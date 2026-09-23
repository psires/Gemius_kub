# Spark Pi seven-decimal validation

## Parameterized submission

To submit a new calculation through the Apache operator, pass the desired
number of digits after the decimal point (1 through 1000):

```bash
./scripts/submit-spark-pi.sh 7
```

The helper discovers every Ready node labelled
`gemius.io/node-role=spark-worker`, creates one executor per node, validates
the generated resources against the Kubernetes API, and submits a uniquely
named application to the `dev` queue. The driver uses the deterministic
Chudnovsky series and prints `PI_RESULT`, `DECIMAL_PLACES`,
`CHUDNOVSKY_TERMS`, `EXECUTOR_NODES`, and `VALIDATION` in its log.

Set `SPARK_PI_GROUP`, `SPARK_PI_NAMESPACE`, or `SPARK_PI_JOB_NAME` only when a
non-default queue, namespace, or stable name is required.

## Fixed all-worker regression

This example runs a deterministic PySpark Pi calculation through the Apache
Spark Kubernetes Operator in the `spark-dev` namespace and therefore in the
YuniKorn `root.spark-dev` queue.

It starts exactly three one-core executors. Required pod anti-affinity spreads
the executors across the three nodes labelled
`gemius.io/node-role=spark-worker`. The application exits unsuccessfully unless
the executor tasks report all three worker nodes and Pi formats as
`3.1415927`.

Apply the example from the repository root:

```bash
kubectl apply -k examples/spark-pi
```

Watch the application and inspect its result:

```bash
kubectl -n spark-dev get sparkapplications.spark.apache.org spark-pi-7 -w
kubectl -n spark-dev logs spark-pi-7-0-driver | \
  grep -E 'PI_RESULT|EXECUTOR_NODES|VALIDATION'
```

The retained completed driver pod consumes no CPU or memory. Remove the
example when its logs are no longer needed:

```bash
kubectl -n spark-dev delete sparkapplication.spark.apache.org spark-pi-7
kubectl -n spark-dev delete configmap spark-pi-7-code
```

## Initial deployment result

The first live run on 2026-09-02 completed successfully with Spark 4.1.1:

```text
PI_RESULT=3.1415927
PI_RAW=3.141592653589661
SAMPLES=30000000
EXECUTOR_NODES=spark-dev-02-worker-10,spark-dev-02-worker-11,spark-dev-02-worker-12
VALIDATION=passed
```

The driver pod was scheduled by YuniKorn with queue label `root.spark-dev`.
