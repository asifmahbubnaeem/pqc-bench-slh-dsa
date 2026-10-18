# PQC-Bench — top-level Makefile.
# Every operation goes through here so behaviour stays reproducible.

.PHONY: help init check-aws bench-up bench-down bench-status wait-ready \
        smoke-test toggle-classical toggle-pq destroy-all cost-check

SHELL := /usr/bin/env bash
TF_DIR := terraform/bench
AWS_PROFILE ?= pqc-bench
AWS_REGION  ?= us-east-1

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------
# One-time setup
# ---------------------------------------------------------------

init: check-aws ## First-time setup: verify AWS creds, terraform init
	@echo "==> Initializing Terraform"
	cd $(TF_DIR) && terraform init
	@if [ ! -f $(TF_DIR)/terraform.tfvars ]; then \
	  echo ""; \
	  echo "!! terraform.tfvars not found. Copy from terraform.tfvars.example:"; \
	  echo "    cp $(TF_DIR)/terraform.tfvars.example $(TF_DIR)/terraform.tfvars"; \
	  echo "   Then edit it with your key_name and allowed_ssh_cidrs."; \
	  exit 1; \
	fi

check-aws: ## Verify AWS credentials work for profile $(AWS_PROFILE)
	@echo "==> Checking AWS profile: $(AWS_PROFILE)"
	@aws --profile $(AWS_PROFILE) sts get-caller-identity > /dev/null || { \
	  echo "!! AWS profile '$(AWS_PROFILE)' is not configured or has invalid credentials."; \
	  echo "   Run:  aws configure --profile $(AWS_PROFILE)"; \
	  exit 1; \
	}
	@echo "OK: $$(aws --profile $(AWS_PROFILE) sts get-caller-identity --query 'Arn' --output text)"

# ---------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------

bench-up: check-aws ## Spin up target + loadgen (spot). ~10 min for user-data.
	@echo "==> terraform apply"
	cd $(TF_DIR) && terraform apply -auto-approve
	@$(MAKE) bench-status

bench-status: ## Show current instance state and IPs
	@cd $(TF_DIR) && terraform output

wait-ready: ## Poll target until user-data finished (nginx-pq running). Up to 15 min.
	@echo "==> Waiting for target readiness (user-data finish)"
	@TARGET_IP=$$(cd $(TF_DIR) && terraform output -raw target_public_ip); \
	KEY_NAME=$$(cd $(TF_DIR) && terraform output -raw target_ssh | awk -F'~/.ssh/' '{print $$2}' | awk '{print $$1}' | sed 's/.pem//'); \
	KEY_FILE="$$HOME/.ssh/$$KEY_NAME.pem"; \
	for i in $$(seq 1 90); do \
	  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$$KEY_FILE" ubuntu@$$TARGET_IP \
	      "test -f /var/lib/pqc-bench-ready" 2>/dev/null; then \
	    echo "==> Target ready after $$((i*10))s"; \
	    exit 0; \
	  fi; \
	  echo "   ... waiting ($$((i*10))s)"; \
	  sleep 10; \
	done; \
	echo "!! Target did not become ready in 15 min. Check /var/log/user-data.log"; \
	exit 1

smoke-test: ## Verify PQ handshake works end-to-end (from loadgen → target)
	@echo "==> Smoke test: PQ handshake from loadgen to target"
	@LOADGEN_IP=$$(cd $(TF_DIR) && terraform output -raw loadgen_public_ip); \
	TARGET_PRIV=$$(cd $(TF_DIR) && terraform output -raw target_private_ip); \
	KEY_NAME=$$(cd $(TF_DIR) && terraform output -raw target_ssh | awk -F'~/.ssh/' '{print $$2}' | awk '{print $$1}' | sed 's/.pem//'); \
	KEY_FILE="$$HOME/.ssh/$$KEY_NAME.pem"; \
	ssh -o StrictHostKeyChecking=no -i "$$KEY_FILE" ubuntu@$$LOADGEN_IP \
	  "/opt/openssl-3.5/bin/openssl s_client -connect $$TARGET_PRIV:443 -groups X25519MLKEM768 -tls1_3 -verify_return_error 0 </dev/null 2>&1 | grep -iE 'negotiated|cipher|peer signature|protocol' | head -8"

bench-down: ## Destroy everything. ALWAYS run after benching.
	@echo "==> terraform destroy"
	cd $(TF_DIR) && terraform destroy -auto-approve
	@echo "==> Torn down. Cost stopped."

destroy-all: bench-down ## Alias for bench-down

# ---------------------------------------------------------------
# Toggle target's TLS config between classical and PQ
# For A/B benchmarks — re-runs terraform apply with a different tls_group.
# Only the nginx.conf on the target changes (via re-provisioning); loadgen untouched.
# ---------------------------------------------------------------

toggle-classical: ## Reconfigure target: TLS group = X25519 (classical baseline)
	cd $(TF_DIR) && terraform apply -auto-approve -var 'tls_group=X25519'

toggle-pq: ## Reconfigure target: TLS group = X25519MLKEM768 (hybrid PQ)
	cd $(TF_DIR) && terraform apply -auto-approve -var 'tls_group=X25519MLKEM768'

# ---------------------------------------------------------------
# Cost visibility
# ---------------------------------------------------------------

cost-check: ## Show any currently-running EC2 instances tagged Project=pqc-bench
	@echo "==> EC2 instances tagged Project=pqc-bench:"
	@aws --profile $(AWS_PROFILE) --region $(AWS_REGION) ec2 describe-instances \
	  --filters "Name=tag:Project,Values=pqc-bench" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
	  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,LaunchTime,Tags[?Key==`Name`].Value|[0]]' \
	  --output table
