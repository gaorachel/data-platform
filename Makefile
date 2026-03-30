LAMBDA_DIR    := ingestion/gharchive
LAMBDA_ZIP    := $(LAMBDA_DIR)/lambda.zip
TF_SHARED     := terraform/shared
TF_GHARCHIVE  := terraform/gharchive
FUNCTION_NAME := gharchive-ingestion

.PHONY: build init plan apply deploy invoke clean shared-init shared-apply

# Build the Lambda zip: pip-install dependencies then bundle with handler.py.
# Run this before 'terraform apply' on a fresh checkout.
build:
	@echo "Building Lambda zip..."
	pip install -r $(LAMBDA_DIR)/requirements.txt -t $(LAMBDA_DIR)/package/ --quiet
	cp $(LAMBDA_DIR)/handler.py $(LAMBDA_DIR)/package/
	cd $(LAMBDA_DIR)/package && zip -r ../lambda.zip . -x "*.pyc" -x "*__pycache__*"
	rm -rf $(LAMBDA_DIR)/package
	@echo "Built: $(LAMBDA_ZIP)"

# Init and apply terraform/shared first — provisions buckets and KMS keys.
# Must be run once before 'make init/plan/apply'.
shared-init:
	cd $(TF_SHARED) && terraform init

shared-apply:
	cd $(TF_SHARED) && terraform apply

# Read the bucket name from shared outputs so gharchive always uses the correct name.
BUCKET_NAME := $(shell cd $(TF_SHARED) && terraform output -raw main_bucket_name 2>/dev/null)

# Terraform init — run once after checkout or after adding a new module
init:
	cd $(TF_GHARCHIVE) && terraform init

# Plan with a fresh build so source_code_hash stays accurate
plan: build
	cd $(TF_GHARCHIVE) && terraform plan -var="s3_bucket_name=$(BUCKET_NAME)"

# Apply with a fresh build
apply: build
	cd $(TF_GHARCHIVE) && terraform apply -var="s3_bucket_name=$(BUCKET_NAME)"

# Push a new zip to an already-provisioned Lambda (skips terraform)
deploy: build
	aws lambda update-function-code \
		--function-name $(FUNCTION_NAME) \
		--zip-file fileb://$(LAMBDA_ZIP)

# Invoke Lambda manually and print the decoded CloudWatch log tail
invoke:
	aws lambda invoke \
		--function-name $(FUNCTION_NAME) \
		--log-type Tail \
		--query 'LogResult' \
		--output text \
		/tmp/lambda-response.json | base64 --decode
	@echo "--- response ---"
	@cat /tmp/lambda-response.json

# Remove build artefacts
clean:
	rm -f $(LAMBDA_ZIP)
	rm -rf $(LAMBDA_DIR)/package
