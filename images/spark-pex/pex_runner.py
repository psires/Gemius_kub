"""Small stable Spark entrypoint that imports application code from a PEX."""

from __future__ import annotations

import importlib
import os
import sys


def _load_entrypoint(spec: str):
    try:
        module_name, function_name = spec.split(":", 1)
    except ValueError as exc:
        raise SystemExit(
            "GEMIUS_SPARK_ENTRYPOINT must use module:function syntax"
        ) from exc

    module = importlib.import_module(module_name)
    try:
        return getattr(module, function_name)
    except AttributeError as exc:
        raise SystemExit(f"Entrypoint function not found: {spec}") from exc


def main() -> int:
    spec = os.environ.get("GEMIUS_SPARK_ENTRYPOINT")
    if not spec:
        raise SystemExit("GEMIUS_SPARK_ENTRYPOINT is required")

    result = _load_entrypoint(spec)()
    return result if isinstance(result, int) else 0


if __name__ == "__main__":
    sys.exit(main())

