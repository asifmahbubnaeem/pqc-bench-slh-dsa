# Phase 3 Night 2 — us-east-1 baseline (openssl s_time variant)

**Why this file supersedes the earlier Night 2 walkthrough:** the first attempt
used Gatling, which failed 100% against ml-dsa-65 certs because JDK 21's X509
parser rejects the ML-DSA-65 public key OID. OpenSSL 3.5 on the loadgen
handles all three cert sig algs natively, so scenario 04 switched to
`openssl s_time`. Trade-off: aggregate mean handshake time per trial, no
p95/p99 granularity. Acceptable: the cert-size × RTT signal manifests as a
mean delta (extra TCP round-trips affect every handshake equally).

**Expected time Night 2:** ~15 min total — ~10 min pure benchmark + ~5 min
terraform swaps and setup. Inside tmux.

## Pre-flight (2 min)

```bash
cd ~/Desktop/Repos/files/pqc-bench

# Extract Night 2 openssl tarball, SKIPPING its top-level README
# (my packaging bug — a top-level README.md would clobber the project's)
tar -xzf ~/Downloads/pqc-bench-phase3-night2-openssl.tar.gz --strip-components=1 \
    --exclude='README.md'

chmod +x scenarios/04-cert-chain-size/run.sh \
         scenarios/04-cert-chain-size/handshake-bench.sh

# Syntax check
bash -n scenarios/04-cert-chain-size/run.sh && echo "run.sh OK"
bash -n scenarios/04-cert-chain-size/handshake-bench.sh && echo "handshake-bench.sh OK"

# Toss any Gatling-era results so there's no mixing
rm -rf results/*-scenario-04-rate*

tmux new -s pqc-04
```

## Step 1 — Spin up us-east-1 infra with cert_type=ecdsa (3 min)

Inside tmux:

```bash
cd ~/Desktop/Repos/files/pqc-bench/terraform/phase-3

terraform apply -auto-approve \
    -var "loadgen_region=us-east-1" \
    -var "cert_type=ecdsa"

TARGET_IP=$(terraform output -raw target_public_ip)
for i in {1..20}; do
  ssh -i ~/.ssh/pqc-bench-key.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    ubuntu@$TARGET_IP "test -f /var/lib/pqc-bench-ready" 2>/dev/null && { echo "READY after ${i}0s"; break; }
  sleep 10
done
```

## Step 2 — Smoke-test the openssl handshake tool once (1 min)

Before the full sweep, confirm `openssl s_time` works end-to-end against the
ECDSA cert (sanity check):

```bash
LOADGEN_IP=$(cd terraform/phase-3 && terraform output -raw loadgen_public_ip)

ssh -i ~/.ssh/pqc-bench-key.pem ubuntu@$LOADGEN_IP \
    "/opt/openssl-3.5/bin/openssl s_time -connect $TARGET_IP:443 -new -time 5 -verify 0 -www /" \
    2>&1 | tail -5
```

Expected: a "N connections in M real seconds" line. If openssl errors out,
abort before the full sweep and share the error.

## Step 3 — Run scenario 04 (~12 min)

```bash
cd ~/Desktop/Repos/files/pqc-bench
./scenarios/04-cert-chain-size/run.sh 60 3 2>&1 | tee /tmp/scenario-04-us-east-1.log
# Args: duration=60s per trial, trials=3
```

Per-arm wall time:
- `ecdsa-us-east-1`: no swap (already applied), 3×60s + overhead ≈ 3.5 min
- `rsa-2048-us-east-1`: terraform swap ~2min, 3×60s ≈ 5.5 min
- `ml-dsa-65-us-east-1`: terraform swap ~2min, 3×60s ≈ 5.5 min

Total: ~15 min.

Each trial prints its live stats:
```
==> ecdsa-us-east-1 trial 1/3  target=XX.XX.XX.XX  duration=60s
==> Stats:
    connections=28000
    wall_seconds=60.00
    avg_ms_per_handshake=2.143
    rate_hs_per_sec=466.67
```

The quick-summary block at the end gives the one-glance view:
```
==> Quick summary:
  ecdsa-us-east-1:
    trial-1  avg=2.143ms
    trial-2  avg=2.098ms
    trial-3  avg=2.165ms
  ...
```

## Step 4 — Verify + quick analysis (2 min)

```bash
RESULTS=results/$(date +%Y-%m-%d)-scenario-04-openssl

find $RESULTS -name stats.txt | wc -l
# Expect: 9

find $RESULTS -name stats.txt -exec grep -H avg_ms_per_handshake {} \;
# Expect: 9 lines, each showing an avg

cat $RESULTS/rtt-probe-us-east-1.txt
# Expect: ping showing ~1 ms avg
```

Optional parse via the Python helper:

```bash
cd analysis
python parse_handshake_bench.py ../$RESULTS
```

Expected pattern at ~1 ms RTT (us-east-1 baseline):
- ecdsa-us-east-1 avg: ~2-3 ms
- rsa-2048-us-east-1 avg: ~3-5 ms (bigger cert → ~1 extra packet, costs ~1ms at low RTT)
- ml-dsa-65-us-east-1 avg: ~5-10 ms (ServerHello spans several extra TCP segments)

Real spread shows up at Night 3 (70 ms RTT) and Night 4 (160 ms RTT), where
each extra packet costs its full RTT.

## Step 5 — Teardown (1 min)

```bash
cd terraform/phase-3
terraform destroy -auto-approve

for r in us-east-1 us-west-2 ap-northeast-1; do
  echo "=== $r ==="
  aws ec2 describe-instances --region $r \
    --filters "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text
done
```

## Night 2 checklist

- [ ] 9 `trial-N/` directories with `stats.txt` files
- [ ] All three `avg_ms_per_handshake` values within reasonable range for 1 ms RTT (ecdsa ≤ rsa-2048 ≤ ml-dsa-65 ordering)
- [ ] `rtt-probe-us-east-1.txt` ping avg close to 1 ms
- [ ] No instances running in any region

## Night 3 preview

Same script, different `loadgen_region`:

```bash
cd terraform/phase-3
terraform apply -auto-approve \
    -var "loadgen_region=us-west-2" \
    -var "cert_type=ecdsa"
# wait readiness
cd ~/Desktop/Repos/files/pqc-bench
./scenarios/04-cert-chain-size/run.sh 60 3 2>&1 | tee /tmp/scenario-04-us-west-2.log
```

Script picks up the new region from `terraform output -raw loadgen_region` and
tags arms accordingly (`ecdsa-us-west-2`, etc.), so Night 2/3/4 results coexist
in one date-stamped folder without collision.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `handshake-bench.sh` prints "could not parse s_time output" | OpenSSL version mismatch — SSH to loadgen, run `/opt/openssl-3.5/bin/openssl version` to confirm 3.5.x, and run s_time manually to see the exact output format. Send me the output. |
| `avg_ms_per_handshake=0.000` | Connection count or wall time parsed as 0. Check `trial-N/openssl.log` for the full stderr. |
| Target apply hangs on 2nd+ swap | Likely `user_data_replace_on_change` dependency chain. If stuck >3 min, Ctrl+C the apply and try again — terraform is idempotent. |
| ssh timeout to loadgen during trial | Keepalives + ServerAlive are set. If recurrent, loadgen is being throttled or there's a routing issue; check `tmux attach` output for `client_loop: send disconnect`. |
