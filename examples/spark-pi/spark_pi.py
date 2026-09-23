#!/usr/bin/env python3
"""Calculate Pi to a requested number of decimal places with PySpark."""

import argparse
import math
import os
from decimal import Decimal, localcontext
from typing import Iterable, List, Tuple

from pyspark.sql import SparkSession


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--digits", type=int, required=True)
    parser.add_argument("--partitions", type=int, required=True)
    parser.add_argument("--expected-nodes", required=True)
    args = parser.parse_args()
    if not 1 <= args.digits <= 1000:
        parser.error("--digits must be between 1 and 1000")
    if args.partitions < 1:
        parser.error("--partitions must be positive")
    return args


def calculate_partition(
    indexes: Iterable[int], working_precision: int
) -> List[Tuple[Decimal, str, int]]:
    """Return a Chudnovsky-series subtotal and the executor node name."""
    node_name = os.environ.get("KUBERNETES_NODE_NAME", "unknown")
    terms = 0
    with localcontext() as context:
        context.prec = working_precision
        subtotal = Decimal(0)
        for index in indexes:
            numerator = Decimal((-1) ** index) * Decimal(math.factorial(6 * index))
            numerator *= Decimal(13_591_409 + 545_140_134 * index)
            denominator = Decimal(math.factorial(3 * index))
            denominator *= Decimal(math.factorial(index)) ** 3
            denominator *= Decimal(640_320) ** (3 * index)
            subtotal += numerator / denominator
            terms += 1
    return [(subtotal, node_name, terms)]


def main() -> None:
    args = parse_args()
    expected_nodes = {node for node in args.expected_nodes.split(",") if node}
    if len(expected_nodes) != args.partitions:
        raise ValueError(
            "The expected-node count must equal the number of Spark partitions"
        )

    working_precision = args.digits + 25
    term_count = args.digits // 14 + 2
    spark = SparkSession.builder.appName(f"spark-pi-{args.digits}").getOrCreate()
    spark.sparkContext.setLogLevel("WARN")

    results = (
        spark.sparkContext.parallelize(range(term_count), args.partitions)
        .barrier()
        .mapPartitions(
            lambda indexes: calculate_partition(indexes, working_precision)
        )
        .collect()
    )

    executor_nodes = {result[1] for result in results}
    processed_terms = sum(result[2] for result in results)
    with localcontext() as context:
        context.prec = working_precision
        series_sum = sum((result[0] for result in results), Decimal(0))
        constant = Decimal(426_880) * Decimal(10_005).sqrt()
        pi_value = constant / series_sum
        formatted_pi = f"{pi_value:.{args.digits}f}"

    print(f"PI_RESULT={formatted_pi}")
    print(f"DECIMAL_PLACES={args.digits}")
    print(f"CHUDNOVSKY_TERMS={processed_terms}")
    print(f"EXECUTOR_NODES={','.join(sorted(executor_nodes))}")

    if processed_terms != term_count:
        raise RuntimeError(
            f"Expected {term_count} Chudnovsky terms, processed {processed_terms}"
        )
    if executor_nodes != expected_nodes:
        raise RuntimeError(
            f"Expected executor nodes {sorted(expected_nodes)}, "
            f"but observed {sorted(executor_nodes)}"
        )

    print("VALIDATION=passed")
    spark.stop()


if __name__ == "__main__":
    main()
