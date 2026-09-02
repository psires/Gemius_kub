# Spark PEX runner image

Build and publish this image in the organization's registry:

```bash
docker build \
  --build-arg SPARK_IMAGE=apache/spark:4.1.1-python3 \
  --tag ghcr.io/psires/gemius-spark-python:4.1.1-python3 \
  images/spark-pex
```

The Spark and Python versions must match the PEX build environment. Production
images should be pinned by digest in the release process.

