SHELL := /usr/bin/env bash

.PHONY: validate render-apache render-kubeflow

validate:
	./scripts/validate.sh

render-apache:
	./scripts/render-job.sh apache examples/jobs/apache-dev.yaml

render-kubeflow:
	./scripts/render-job.sh kubeflow examples/jobs/kubeflow-dev.yaml

