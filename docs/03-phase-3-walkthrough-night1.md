# Phase 3 Night 1 — Prep & Smoke Test

**Goal:** by end of night, you can spin up Phase 3 infra with loadgen in
us-east-1, swap `cert_type` between the three cert types, and have Gatling
hit the target over its PUBLIC IP (not VPC-private). Cross-region loadgens
stay dormant tonight — they get exercised Night 2–4.

**Expected time:** 60–90 min (most of it is AWS AMI copies running async in
the background while you edit terraform).

## Step 1 — Extract tarball and verify (2 min)

```bash
cd ~/Desktop/Repos/files/pqc-bench
tar -xzf ~/Downloads/pqc-bench-phase3.tar.gz --strip-components=1
ls scripts/copy-loadgen-ami.sh \
   terraform/target/user-data-fast.sh.tftpl \
   terraform/phase-3/main.tf \
   docs/03-phase-3-walkthrough-night1.md && echo "PHASE3 FILES OK"
```

## Step 2 — Kick off AMI copies (5 min hands-on, 10 min async)

```bash
chmod +x scripts/copy-loadgen-ami.sh
./scripts/copy-loadgen-ami.sh
# Prints two new AMI IDs: loadgen_ami_us_west_2 and loadgen_ami_ap_northeast_1
# Save these — you'll paste them into terraform.tfvars at Step 5.
```

AWS copies images asynchronously (5–10 min each). Let them run in the
background while you do Steps 3–4.

**Poll for completion** anytime:
```bash
aws ec2 describe-images --region us-west-2    --image-ids ami-XXXX --query 'Images[0].State'
aws ec2 describe-images --region ap-northeast-1 --image-ids ami-XXXX --query 'Images[0].State'
# Expect: "available" when ready
```

## Step 3 — Create cross-region EC2 keypairs (5 min)

AWS keypairs are region-scoped. Simplest path: reuse the SAME private key
material across all three regions by importing your existing public key
under new names in us-west-2 and ap-northeast-1.

```bash
# Dump the public half of your existing pqc-bench key
PUBKEY=$(ssh-keygen -y -f ~/.ssh/pqc-bench-key.pem)
echo "$PUBKEY"

# Import it under the names Phase 3 terraform expects
aws ec2 import-key-pair --region us-west-2 \
    --key-name pqc-bench-key-west \
    --public-key-material "$(echo -n "$PUBKEY" | base64 -w 0)"

aws ec2 import-key-pair --region ap-northeast-1 \
    --key-name pqc-bench-key-tokyo \
    --public-key-material "$(echo -n "$PUBKEY" | base64 -w 0)"
```

After this, the same `~/.ssh/pqc-bench-key.pem` works for all three regions.

## Step 4 — Apply the target module patches (10 min)

Open `docs/03-phase-3-walkthrough-night1.md`'s companion patch files:

**4a.** Append the contents of
`terraform/target/variables.tf.additions` to the END of
`terraform/target/variables.tf`:

```bash
cat terraform/target/variables.tf.additions >> terraform/target/variables.tf
```

**4b.** Apply the two main.tf patches by hand from
`terraform/target/main.tf.patches.md`:
- Patch 1: SG ingress rule becomes conditional on `allow_public_443`
- Patch 2: Thread `cert_type` into both templatefile() calls

**4c.** Verify:
```bash
cd terraform/target
terraform fmt
grep -c 'cert_type\|allow_public_443' main.tf variables.tf
# Expect ≥4 matches total
```

The Phase 2 user-data file (`user-data-fast.sh.tftpl`) is already overwritten
by the tarball — it now generates RSA-2048 alongside the two existing certs
and picks one based on `${cert_type}`.

## Step 5 — Fill in region-specific AMIs (2 min)

Once the AMI copies finish:

```bash
cd terraform/phase-3

cat > terraform.tfvars <<EOF
loadgen_ami_us_west_2      = "ami-XXXX_from_step_2"
loadgen_ami_ap_northeast_1 = "ami-YYYY_from_step_2"
EOF
```

## Step 6 — Terraform init (2 min)

```bash
cd terraform/phase-3
terraform init
# Expect: "Terraform has been successfully initialized"
# You'll see 3 provider instances listed (us-east-1, us-west-2, ap-northeast-1)
```

## Step 7 — Smoke test: us-east-1 loadgen, cert_type=ecdsa (5 min)

```bash
cd terraform/phase-3
terraform apply -auto-approve \
    -var "loadgen_region=us-east-1" \
    -var "cert_type=ecdsa"

TARGET_IP=$(terraform output -raw target_public_ip)
LOADGEN_IP=$(terraform output -raw loadgen_public_ip)
echo "Target public IP: $TARGET_IP"
echo "Loadgen IP:       $LOADGEN_IP"

# Readiness
for i in {1..20}; do
  ssh -i ~/.ssh/pqc-bench-key.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    ubuntu@$TARGET_IP "test -f /var/lib/pqc-bench-ready" 2>/dev/null && { echo "READY after ${i}0s"; break; }
  sleep 10
done
```

### 7a. Verify the cert is actually ECDSA

```bash
# From your laptop (or loadgen), probe the TLS cert:
echo | openssl s_client -connect $TARGET_IP:443 -servername pqc-bench-target 2>/dev/null \
     | openssl x509 -noout -text | grep 'Public Key Algorithm\|Signature Algorithm'
# Expect to see "id-ecPublicKey" and "ecdsa-with-SHA256"
```

### 7b. Verify cross-region reachability pattern (loadgen → target public IP)

```bash
# Hit target from loadgen via its PUBLIC IP (not private)
ssh -i ~/.ssh/pqc-bench-key.pem ubuntu@$LOADGEN_IP \
    "curl -ks --max-time 5 -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' https://$TARGET_IP/"
# Expect: HTTP 200 in ~0.0Xs
```

Private IP won't work from a different VPC when we get to cross-region nights.

## Step 8 — Swap cert_type to verify RSA-2048 (3 min)

```bash
terraform apply -auto-approve \
    -var "loadgen_region=us-east-1" \
    -var "cert_type=rsa-2048"

# Target gets recreated (user_data_replace_on_change=true)
# Wait for readiness again, then verify
TARGET_IP=$(terraform output -raw target_public_ip)
for i in {1..20}; do
  ssh -i ~/.ssh/pqc-bench-key.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    ubuntu@$TARGET_IP "test -f /var/lib/pqc-bench-ready" && { echo "READY"; break; }
  sleep 10
done

echo | openssl s_client -connect $TARGET_IP:443 2>/dev/null \
     | openssl x509 -noout -text | grep 'Public Key Algorithm'
# Expect: "rsaEncryption" and 2048 bits
```

## Step 9 — Swap to ml-dsa-65, verify (3 min)

```bash
terraform apply -auto-approve \
    -var "loadgen_region=us-east-1" \
    -var "cert_type=ml-dsa-65"

# After readiness:
TARGET_IP=$(terraform output -raw target_public_ip)
echo | openssl s_client -connect $TARGET_IP:443 2>/dev/null \
     | openssl x509 -noout -text | grep 'Public Key Algorithm\|Signature Algorithm'
# Expect: "ML-DSA-65" in both lines

# Check cert file size on the target — this is the key Phase 3 measurement
ssh -i ~/.ssh/pqc-bench-key.pem ubuntu@$TARGET_IP \
    "wc -c /etc/pki/pq/server-*.crt"
# Expect roughly:
#   server-ecdsa.crt   : ~400-500 B
#   server-rsa2048.crt : ~900-1100 B
#   server-mldsa65.crt : ~3500-4000 B
# The signature portion of each is what Phase 3 measures the latency cost of.
```

**This is the measurement that makes Phase 3 worth doing** — if the cert
size ratios aren't ~1 : 2 : 8, something is wrong with the user-data cert
generation and we need to investigate before Night 2.

## Step 10 — Teardown (1 min)

```bash
terraform destroy -auto-approve

aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' \
  --output text
# Expect: empty

# AMIs stay (one in each of 3 regions now) — keep them for Nights 2-4.
```

## Night 1 checklist before closing laptop

- [ ] AMI copies to us-west-2 and ap-northeast-1 completed (State=available)
- [ ] Keypairs imported into us-west-2 and ap-northeast-1
- [ ] `terraform/target/variables.tf` has `cert_type` and `allow_public_443` vars
- [ ] `terraform/target/main.tf` has the SG patch and templatefile patch
- [ ] Phase 3 user-data generates ML-DSA-65, ECDSA, AND RSA-2048 certs
- [ ] Fresh `terraform apply` → ready → cert verification worked for all 3 cert_types
- [ ] Target cert file sizes landed in the expected 1 : 2 : 8 ratio
- [ ] `terraform destroy` clean, no stray instances in any region

## Night 2 preview

Night 2 is the first real benchmark: us-east-1 loadgen running scenario 04
against the target with each of the 3 cert types. 9 trials × ~6 min each,
~55 min pure benchmark. Script and simulation ship in the Night 2 tarball,
built once I see Night 1's smoke-test numbers (specifically, the cert file
sizes — those confirm the signal we're measuring is real).

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `terraform init` fails on provider auth | AWS profile `pqc-bench` doesn't have creds for all 3 regions | `aws configure --profile pqc-bench` + verify `aws sts get-caller-identity --region ap-northeast-1` works |
| user-data fails: `cert_type must be one of…` | Typo in `-var "cert_type=XXX"` | Values are `ecdsa`, `rsa-2048`, `ml-dsa-65` (hyphenated) |
| Target SSH refused | SG still restricts to loadgen SG | Confirm `allow_public_443 = true` passed through phase-3/main.tf → target module |
| curl from loadgen to target public IP times out | Target SG config wrong | Check: `aws ec2 describe-security-groups --filters "Name=group-name,Values=pqc-bench-phase3-target"` — should show 443/tcp from 0.0.0.0/0 |
| openssl s_client shows wrong cert | Target boot cached old nginx config | SSH into target: `sudo systemctl status nginx-pq; cat /etc/pki/pq/server-*.crt | head -2` — if wrong, `sudo touch /tmp/force-reboot && sudo reboot` and let terraform re-apply |
| AMI copy stuck in `pending` for >15 min | AWS region capacity blip | Rare; just wait, or cancel and retry: `aws ec2 deregister-image --region us-west-2 --image-id ami-XXXX` then rerun copy script |
