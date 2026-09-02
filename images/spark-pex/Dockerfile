ARG SPARK_IMAGE=apache/spark:4.1.1-python3
FROM ${SPARK_IMAGE}

USER 0
COPY --chown=185:185 pex_runner.py /opt/spark/work-dir/pex_runner.py
USER 185

