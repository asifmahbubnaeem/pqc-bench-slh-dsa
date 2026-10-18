# Phase 2 — Saturday Execution Playbook

Scenarios 02 (session resumption) + 03 (payload sweep), combined into one
weekend sitting. The infra from Phase 1 is reused; only the target
user-data and the Gatling simulations change.

## What's new vs Phase 1

| Thing                           | Phase 1              | Phase 2                                              |
|---------------------------------|----------------------|------------------------------------------------------|
| Target endpoints                | `GET /` (3 bytes)    | `GET /`, `/payload/{100B,10K,100K,1M}` (random bins) |
| TLS session cache               | off (didn't matter)  | **on**, 1h timeout, tickets enabled                  |
| Certs served                    | ECDSA + ML-DSA-65    | **unchanged**                                        |
| Client-side TLS reuse           | n/a                  | `shareConnections()` toggle picks fresh vs resumed   |
| Gatling simulations             | 1 (FreshHandshake)   | 3 (Fresh, Resumed, PayloadSweep)                     |
| Analysis                        | manual HTML scrape   | `parse_gatling.py` reads `stats.json`                |

The target config is identical between scenarios 02 and 03. The only
terraform knob that changes is `tls_group`.

## Pre-flight (Friday night, 15 min)

1. **Drop the Phase 2 files into the repo.**
   The tarball lays out as the project root. From repo root:
   ```bash
   tar -xzf pqc-bench-phase2.tar.gz -C .
   ```
   This overwrites `terraform/target/user-data-fast.sh.tftpl` with the
   Phase 2 version (new endpoints + session cache) and adds:
   - `scenarios/02-resumption/`
   - `scenarios/03-payload-sweep/`
   - `analysis/02-resumption.ipynb`
   - `analysis/03-payload-sweep.ipynb`
   - `analysis/parse_gatling.py`
   - `docs/02-phase-2-walkthrough.md` (this file)

2. **Rebuild the target AMI? No.** The AMI already has nginx-pq + openssl 3.5
   + certs; what changes is user-data content, which runs at every boot.
   The existing `target_ami` (`ami-0439939f24b73421c`) is fine. Verify:
   ```bash
   cat ~/.ami-id      # should still name the two Phase 1 AMIs
   ```

3. **Sanity-check locally**:
   ```bash
   bash -n scenarios/02-resumption/run.sh
   bash -n scenarios/03-payload-sweep/run.sh
   ```

4. **Commit the Phase 2 scaffolding** so Saturday-morning you is starting
   from a clean tree:
   ```bash
   git add .
   git commit -m "phase 2: scenarios 02 + 03, session resumption + payload sweep"
   git push
   ```

## Saturday morning — the actual run

Total wall time: **~3.5 hours** of benchmarking + ~20 min setup/teardown.

### 1. Spin up (5 min)

```bash
cd terraform/bench
make bench-up    # uses the saved AMIs; terraform apply
# or: terraform apply -auto-approve -var "tls_group=X25519"
```

The first `apply` boots both instances. User-data runs on the target and
generates the payload bins + enables session cache. Confirm readiness:

```bash
TARGET_IP=$(terraform output -raw target_public_ip)
ssh -i ~/.ssh/pqc-bench-key.pem ubuntu@$TARGET_IP "test -f /var/lib/pqc-bench-ready && echo READY"
```

Sanity-check endpoints respond:
```bash
LOADGEN_IP=$(terraform output -raw loadgen_public_ip)
TARGET_PRIV=$(terraform output -raw target_private_ip)
ssh -i ~/.ssh/pqc-bench-key.pem ubuntu@$LOADGEN_IP \
  "curl -k --max-time 5 https://$TARGET_PRIV/ ; \
   curl -ks --max-time 5 https://$TARGET_PRIV/payload/100B | wc -c; \
   curl -ks --max-time 5 https://$TARGET_PRIV/payload/1M   | wc -c"
# Expect: OK ; 100 ; 1048576
```

### 2. Scenario 02 — resumption (60 min benchmark)

```bash
cd ~/pqc-bench
./scenarios/02-resumption/run.sh 300 3 10
# rate=300 users/sec, trials=3, requestsPerUser=10
```

What happens:
- Reuses existing `X25519` target → runs `classical-fresh` × 3 trials
- No terraform re-apply, runs `classical-resumed` × 3 trials
- `terraform apply` to swap to `X25519MLKEM768` → waits for readiness
- Runs `pq-fresh` × 3 trials
- No re-apply, runs `pq-resumed` × 3 trials

12 trials × 5-min measurement + 30s warmup each = **~66 min pure bench**
+ ~3 min for the single terraform swap.

Results land in `results/<date>-scenario-02-rate300/<arm>/trial-N/`.

### 3. Scenario 03 — payload sweep (120 min benchmark)

The scenario-02 run finishes with the target on `X25519MLKEM768` (last arm
is `pq-resumed`). The scenario-03 run orders groups as `classical` then
`pq` — so there's a terraform swap at the start, then one more swap mid-way.

```bash
./scenarios/03-payload-sweep/run.sh 200 3 10
# rate=200 users/sec, trials=3, requestsPerUser=10
```

Lower rate than scenario 02 because 1M payloads × 200 users/sec = ~1.6 Gbps
sustained — c7g.large has 12.5 Gbps burst but we don't want to saturate
NIC and conflate PQ overhead with buffer-bloat. 200 rps × 10 reqs/user
across 4 payload sizes is still ~24k requests per trial.

24 trials × 5-min + 30s warmup = **~132 min pure bench** + ~3 min for the
one terraform swap.

Results in `results/<date>-scenario-03-rate200/<arm>/trial-N/`.

### 4. Tear down (2 min)

```bash
cd terraform/bench
make bench-down     # terraform destroy
```

Verify no stray instances:
```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType]' \
  --output text
```

### 5. Save the raw results

```bash
cd ~/pqc-bench
tar -czf results/phase-2-raw-$(date +%Y-%m-%d).tar.gz \
    results/*-scenario-02-* results/*-scenario-03-*
# Push to the repo under results/, or S3 if too big (should be <10 MB total)
```

## Analysis (Sunday or weeknight)

```bash
cd ~/pqc-bench/analysis
pip install pandas matplotlib jupyter
jupyter lab 02-resumption.ipynb 03-payload-sweep.ipynb
```

Edit the `RESULTS = "../results/..."` line in each notebook's second cell
to point at the directory `run.sh` printed. Run all cells. Charts dump to
PNG in the same directory.

For a quick CLI check without Jupyter:
```bash
python analysis/parse_gatling.py results/2026-10-DD-scenario-02-rate300
```

## Troubleshooting cheat sheet

| Symptom                                       | What to check                                                                 |
|-----------------------------------------------|-------------------------------------------------------------------------------|
| `target_tls_group` output empty               | First `terraform apply` of the day — one-time, the script handles it         |
| `No results` after a trial                    | Loadgen `gatling:test` likely failed. SSH in, re-run manually, read maven log|
| `SSLV3_ALERT_HANDSHAKE_FAILURE` from loadgen  | Target didn't get ECDSA cert — check `/etc/pki/pq/server-ecdsa.*` on target  |
| p95 flat-lined at 30s                         | 99%-success assertion probably tripped. Lower rate, re-run                   |
| Nothing in `stats.json`                       | Older Gatling → `js/stats.json`. `parse_gatling.py` globs recursively        |
| 1M payload returns < 1 MB                     | `dd` in user-data didn't finish. SSH to target: `ls -la /var/www/pqc-bench/` |
| `terraform apply` complains instance exists   | `make bench-down` first, then `make bench-up`                                 |

## Cost estimate

- c7g.large spot ≈ $0.04/hr × 2 instances = $0.08/hr
- Total runtime: ~3.5h bench + ~1h idle during analysis if left up = ~$0.40
- EBS gp3 20GB × 2 for a weekend ≈ $0.10
- Data transfer out: ~0 (all intra-AZ private IP, same subnet)
- **Total weekend: well under $1**

Tear down as soon as the raw results are tarred.

## What goes into the Part 2 blog post

Target structure (write after analysis, same shape as Part 1):

1. **Hook**: "Phase 1 said PQ costs 11ms. But production traffic doesn't
   handshake every request. What happens when we turn session resumption
   on?"
2. **Setup diff**: one-paragraph description of the toggle (session cache +
   `shareConnections`), link to Part 1 for infra
3. **Scenario 02 results**: 2 charts (p50/p95/p99 bar chart, overhead %
   chart). The headline number is the resumed PQ overhead at p95
4. **Scenario 03 results**: 1 chart (p95 vs payload size, two lines
   + overhead annotation). Headline: whether the curve is flat
5. **Takeaways**: 3 bullets. "If you resume, PQ is nearly free. The record
   layer doesn't care which KEM you used. Fresh-handshake benchmarks
   understate how little the migration will cost in production."
6. **What's next**: Phase 3 teaser — AMI pre-warmed vs cold, or
   certificate-chain size impact (ML-DSA-65 sig is ~3.3 KB vs ECDSA ~70B)

Keep it under 1500 words, same voice as Part 1.
