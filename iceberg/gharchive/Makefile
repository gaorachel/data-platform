# Makefile for the gharchive → Iceberg PySpark pipeline.
#
# Config comes from .env (gitignored). Copy .env.example → .env and populate
# from Terraform output:
#
#   cd ../../terraform/iceberg && terraform init && terraform output
#
# Typical flow:
#   make upload-job
#   make submit START=2026-04-01 END=2026-04-14
#   make logs   JOB_ID=<jobRunId returned by submit>
#   make status JOB_ID=<jobRunId>

-include .env

JOB_FILE       := load_gharchive_to_iceberg.py
JOBS_S3_PREFIX  = s3://$(S3_BUCKET)/iceberg/gharchive/jobs
ENTRY_POINT     = $(JOBS_S3_PREFIX)/$(JOB_FILE)
LOG_GROUP      := /aws/emr-serverless/gharchive-iceberg

# Iceberg + Glue + S3FileIO wiring. Kept in the Makefile (not the job code)
# so the job stays catalog-agnostic — it just reads/writes glue_catalog.*
# and the infra layer decides what glue_catalog points at.
#
# Driver/executor sizes are set explicitly here so they stay well within the
# application's maximum_capacity (16 vCPU / 64 GB). EMR Serverless defaults
# (4 vCPU / 14 GB per container) would exhaust the old 4 vCPU cap before any
# executor could start.
#   driver:   2 vCPU / 4 GB → 1 driver container
#   executor: 2 vCPU / 8 GB → up to 6 executors (12 vCPU / 48 GB used)
SPARK_CONF = \
--conf spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog \
--conf spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog \
--conf spark.sql.catalog.glue_catalog.warehouse=s3://$(S3_BUCKET)/iceberg/ \
--conf spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO \
--conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
--conf spark.emr-serverless.driver.cores=2 \
--conf spark.emr-serverless.driver.memory=4g \
--conf spark.executor.cores=2 \
--conf spark.executor.memory=8g \
--conf spark.dynamicAllocation.maxExecutors=6

# check-env is a silent guard run before any target that talks to AWS.
# Kept as a shell check (not a Make-level $(error)) so `make help` still
# works before the user has created .env.
define _require_env
	@if [ -z "$(AWS_REGION)" ] || [ -z "$(S3_BUCKET)" ] || [ -z "$(EMR_APPLICATION_ID)" ] || [ -z "$(EMR_EXECUTION_ROLE_ARN)" ]; then \
		echo "ERROR: missing env vars. Copy .env.example to .env and fill in from terraform output."; \
		exit 1; \
	fi
endef

.PHONY: help upload-job submit logs status

help:
	@echo "Targets:"
	@echo "  upload-job                   sync jobs/ to s3://<bucket>/iceberg/gharchive/jobs/"
	@echo "  submit START=... END=...     submit a job run for [START, END] (inclusive, YYYY-MM-DD)"
	@echo "  logs   JOB_ID=...            tail CloudWatch logs for a job run"
	@echo "  status JOB_ID=...            print job run status"

upload-job:
	$(_require_env)
	aws s3 sync jobs/ $(JOBS_S3_PREFIX)/ \
		--region $(AWS_REGION) \
		--exclude "__pycache__/*" \
		--exclude "*.pyc"

submit:
	$(_require_env)
	@test -n "$(START)" || (echo "ERROR: pass START=YYYY-MM-DD" && exit 1)
	@test -n "$(END)"   || (echo "ERROR: pass END=YYYY-MM-DD"   && exit 1)
	aws emr-serverless start-job-run \
		--region $(AWS_REGION) \
		--application-id $(EMR_APPLICATION_ID) \
		--execution-role-arn $(EMR_EXECUTION_ROLE_ARN) \
		--name "gharchive-$(START)-to-$(END)" \
		--job-driver '{"sparkSubmit":{"entryPoint":"$(ENTRY_POINT)","entryPointArguments":["--start-date","$(START)","--end-date","$(END)","--bucket","$(S3_BUCKET)"],"sparkSubmitParameters":"$(SPARK_CONF)"}}' \
		--configuration-overrides '{"monitoringConfiguration":{"cloudWatchLoggingConfiguration":{"enabled":true,"logGroupName":"$(LOG_GROUP)"}}}' \
		--query '{jobRunId:jobRunId, applicationId:applicationId}' \
		--output table

status:
	$(_require_env)
	@test -n "$(JOB_ID)" || (echo "ERROR: pass JOB_ID=<jobRunId>" && exit 1)
	aws emr-serverless get-job-run \
		--region $(AWS_REGION) \
		--application-id $(EMR_APPLICATION_ID) \
		--job-run-id $(JOB_ID) \
		--query 'jobRun.{state:state, stateDetails:stateDetails, createdAt:createdAt, totalExecutionDurationSeconds:totalExecutionDurationSeconds, billedResourceUtilization:billedResourceUtilization}' \
		--output table

# EMR Serverless writes driver + executor log streams under
# applications/<app>/jobs/<job>/... once CloudWatch logging is enabled via
# the start-job-run configuration-overrides (see submit target above).
logs:
	$(_require_env)
	@test -n "$(JOB_ID)" || (echo "ERROR: pass JOB_ID=<jobRunId>" && exit 1)
	aws logs tail $(LOG_GROUP) \
		--region $(AWS_REGION) \
		--log-stream-name-prefix "/applications/$(EMR_APPLICATION_ID)/jobs/$(JOB_ID)" \
		--follow
