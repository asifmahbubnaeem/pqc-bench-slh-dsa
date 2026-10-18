# Phase 0 — Foundation setup

**Goal:** end this weekend with `make bench-up` reliably spinning up a nginx-pq target and a Gatling-ready loadgen in ~10 minutes, and `make bench-down` tearing them down. Nothing measured yet.

**Estimated cost for this phase:** ~$0.10 for the first successful `bench-up`.

---

## 0. Prerequisites (local)

Install on your laptop:

- `terraform` >= 1.6 — `brew install terraform` / `apt install terraform`
- `aws-cli` v2 — `brew install awscli` / [AWS install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- `make` (already on macOS/Linux)
- An SSH key. If you don't have one:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/pqc-bench-key
  ```

---

## 1. Create an IAM user scoped to this project

Best practice: don't use root credentials. Create a dedicated IAM user with programmatic access, scoped to what this project actually needs.

In the AWS console:

1. IAM → Users → Create user
2. Name: `pqc-bench`
3. Attach policies directly (for now — you can lock this down later):
   - `AmazonEC2FullAccess` — for target/loadgen management
   - `AmazonVPCFullAccess` — for the tiny VPC we create per run
4. Create user → Security credentials tab → Create access key
5. Use case: "Command Line Interface (CLI)"
6. **Save the access key ID and secret access key** — you'll need them next.

**Once you have real runs happening**, tighten this to a custom policy limited to the tags this project uses (`Project=pqc-bench`) — but that's Phase 4 hygiene, not Phase 0 blocking.

---

## 2. Configure the local AWS profile

On your laptop:

```bash
aws configure --profile pqc-bench
# AWS Access Key ID:     <paste from step 1>
# AWS Secret Access Key: <paste from step 1>
# Default region name:   us-east-1
# Default output format: json
```

Verify:

```bash
aws --profile pqc-bench sts get-caller-identity
# Should print your IAM user ARN
```

---

## 3. Import your SSH key to AWS

```bash
aws --profile pqc-bench ec2 import-key-pair \
    --region us-east-1 \
    --key-name pqc-bench-key \
    --public-key-material fileb://~/.ssh/pqc-bench-key.pub
```

If you already have an SSH key you want to use, substitute the path to its `.pub` file.

---

## 4. Set up your project config

```bash
cd terraform/bench
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
profile           = "pqc-bench"
region            = "us-east-1"
key_name          = "pqc-bench-key"
allowed_ssh_cidrs = ["YOUR_LAPTOP_IP/32"]   # get from: curl ifconfig.me
```

The `allowed_ssh_cidrs` restricts SSH ingress to your laptop's IP only. If your home IP changes (dynamic ISP), update this file and re-run `make bench-up`.

---

## 5. First bench-up

```bash
cd ../..  # back to project root
make init       # runs terraform init, checks AWS creds
make bench-up   # ~2 min for terraform, then ~10 min for user-data
```

The `terraform apply` completes fast (< 2 min) but the target's user-data takes another ~8-10 minutes to build OpenSSL 3.5 and nginx-pq. Use:

```bash
make wait-ready   # polls until /var/lib/pqc-bench-ready exists on target
```

Once ready:

```bash
make smoke-test   # verifies PQ handshake from loadgen to target
```

Expected output includes:
```
Negotiated TLS1.3 group: X25519MLKEM768
Peer signature type: mldsa65
```

Both lines = Phase 0 success. You've automated the manual setup we built earlier.

---

## 6. Tear down (do this every time!)

```bash
make bench-down
```

Verify nothing is left running:

```bash
make cost-check
# Should show no instances
```

---

## 7. Set an AWS budget alert

While your terminal is idle:

1. AWS Console → Billing → Budgets → Create budget
2. Template: "Zero spend budget" (or custom at $10/month)
3. Alert email: your email
4. Save

This is a safety net — if you ever forget `bench-down` you'll get a warning email at $1 spend instead of a $50 bill at end of month.

---

## Success criterion for Phase 0

You should be able to run this sequence in 15 minutes flat, get all green:

```bash
make bench-up      # ~2 min
make wait-ready    # ~8 min
make smoke-test    # <10 sec — shows X25519MLKEM768 negotiated
make bench-down    # ~1 min
make cost-check    # empty output
```

If all four green, you're done with Phase 0 and ready for Phase 1: **measurement.**

---

## Troubleshooting

**`make bench-up` fails with "InsufficientInstanceCapacity"**
Spot capacity in the AZ is temporarily exhausted. Either:
- Wait 10 min and retry
- Switch `instance_type` in `terraform.tfvars` to `c7g.xlarge` or `t3.medium`
- Switch region to `us-west-2` in `terraform.tfvars`

**`make wait-ready` times out after 15 min**
User-data crashed. SSH in and check the log:
```bash
KEY=~/.ssh/pqc-bench-key.pem
IP=$(cd terraform/bench && terraform output -raw target_public_ip)
ssh -i $KEY ubuntu@$IP "sudo tail -50 /var/log/user-data.log"
```
Common issue: apt mirrors slow, OpenSSL build OOM'd (increase to c7g.xlarge for the first bench-up).

**`make smoke-test` shows "connection refused"**
nginx-pq didn't start. On the target:
```bash
sudo systemctl status nginx-pq
sudo journalctl -u nginx-pq -n 30
```

**`make bench-down` fails with dependency errors**
Something outside Terraform is using the VPC (rare). Force with:
```bash
cd terraform/bench && terraform destroy -auto-approve -refresh=false
```
Or in AWS Console: EC2 → Instances → terminate anything tagged `Project=pqc-bench`, then VPC → delete the pqc-bench VPC.
