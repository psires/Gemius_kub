#!/usr/bin/env python3
"""Calculate Pi deterministically and verify execution on every Spark worker."""

import math
import os
from typing import Iterable, List, Tuple

from pyspark.sql import SparkSession


EXPECTED_NODES = {
    "spark-dev-02-worker-10",
    "spark-dev-02-worker-11",
    "spark-dev-02-worker-12",
}
PARTITIONS = len(EXPECTED_NODES)
STEPS = 30_000_000


def integrate_partition(partition_indexes: Iterable[int]) -> List[Tuple[float, str, int]]:
    """Return this executor's midpoint-integration subtotal and node name."""
    node_name = os.environ.get("KUBERNETES_NODE_NAME", "unknown")
    subtotal = 0.0
    sample_count = 0

    for partition_index in partition_indexes:
        for sample_index in range(partition_index, STEPS, PARTITIONS):
            midpoint = (sample_index + 0.5) / STEPS
            subtotal += 4.0 / (1.0 + midpoint * midpoint)
            sample_count += 1

    return [(subtotal, node_name, sample_count)]


def main() -> None:
    spark = SparkSession.builder.appName("spark-pi-7").getOrCreate()
    spark.sparkContext.setLogLevel("WARN")

    results = (
        spark.sparkContext.parallelize(range(PARTITIONS), PARTITIONS)
        .mapPartitions(integrate_partition)
        .collect()
    )

    pi_value = math.fsum(result[0] for result in results) / STEPS
    executor_nodes = {result[1] for result in results}
    processed_samples = sum(result[2] for result in results)
    formatted_pi = f"{pi_value:.7f}"

    print(f"PI_RESULT={formatted_pi}")
    print(f"PI_RAW={pi_value:.15f}")
    print(f"SAMPLES={processed_samples}")
    print(f"EXECUTOR_NODES={','.join(sorted(executor_nodes))}")

    if processed_samples != STEPS:
        raise RuntimeError(
            f"Expected {STEPS} samples, but executors processed {processed_samples}"
        )
    if executor_nodes != EXPECTED_NODES:
        raise RuntimeError(
            f"Expected executor nodes {sorted(EXPECTED_NODES)}, "
            f"but observed {sorted(executor_nodes)}"
        )
    if formatted_pi != "3.1415927":
        raise RuntimeError(f"Expected Pi to seven decimal places, got {formatted_pi}")

    print("VALIDATION=passed")
    spark.stop()


if __name__ == "__main__":
    main()
