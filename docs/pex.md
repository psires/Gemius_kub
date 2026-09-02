# PEX application contract

Spark distributes the PEX as a regular file through `spark.files`. The PEX is
then selected through `spark.pyspark.python` for Python workers. Because PEX
does not embed Python itself, the PEX build interpreter and the Python runtime
inside the Spark image must have compatible versions and platforms.

## Required PEX shape

- Build for the same Linux architecture and Python minor version as the Spark
  image.
- Include application code and Python dependencies.
- Do not depend on a different PySpark version than the Spark runtime.
- PEX files with a fixed entrypoint are supported by setting
  `PEX_INTERPRETER=1`, which the job chart does by default.
- Publish under an immutable, versioned URI and retain its digest in release
  metadata.

## Runner contract

The image contains `/opt/spark/work-dir/pex_runner.py`. The job value
`pex.entrypoint` must use `module:function` syntax. The runner imports the
function from the PEX environment, preserves Spark's application arguments in
`sys.argv`, invokes the function with no positional parameters, and propagates
an integer return value as the process exit code.

Example:

```python
def main():
    from pyspark.sql import SparkSession

    spark = SparkSession.builder.getOrCreate()
    # application logic
```

Example values:

```yaml
pex:
  uri: s3a://spark-artifacts/jobs/audience/2026.09.0/audience.pex
  fileName: audience.pex
  entrypoint: audience.main:main
```

The URI scheme may require Hadoop connector JARs and workload identity
configuration in the image. Baking frequently executed PEX files into an OCI
image is also supported: use a `local:///...` URI and ensure `fileName` matches
the localized file.

