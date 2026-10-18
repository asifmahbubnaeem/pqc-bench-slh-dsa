# PQC-Bench

Reproducible post-quantum TLS performance benchmarks on AWS.

**What it measures:** the real-world cost of enabling `X25519MLKEM768` (NIST FIPS 203 hybrid PQ key exchange) vs classical `X25519` in TLS 1.3, under realistic load.

**Design goals:**
- **Reproducible.** Every published number ships with the Terraform, the Gatling simulation, and the raw results.
- **Cheap.** A full scenario run costs well under $1 on AWS. Sub-$5/month if you re-run monthly.
- **Independent.** Not a vendor benchmark, not a library microbenchmark.

## Writeups

- **Part 1 — Fresh-handshake latency:** [Measuring X25519MLKEM768 costs on a $0.04/hour Graviton3](https://dev.to/asif_naeem_bd5842be56bfcd/pqc-bench-part-1-measuring-x25519mlkem768-costs-on-a-004hour-graviton3-2b2d)
- **Part 2 — Session resumption + payload sweep:** _(coming soon)_

## Quick start

Prerequisites: `terraform >= 1.6`, `aws-cli >= 2.15`, `make`, an AWS account with an IAM user configured as profile `pqc-bench`.

```bash
# One-time setup
make init

# Spin up target + load generator (same-AZ, both c7g.large)
make bench-up

# Run a scenario (pick one or run all three)
./scenarios/01-fresh-handshake-latency/run.sh 1000 3        # ~45 min
./scenarios/02-resumption/run.sh            300 3 10        # ~70 min

cd terraform/bench && terraform apply -auto-approve -var "use_spot=false" -var "tls_group=X25519"
cd ../..
./scenarios/03-payload-sweep/run.sh 200 3 10                # ~2h15m

# Analyse (per-scenario Jupyter notebooks in analysis/)
cd analysis && jupyter lab

# Tear everything down (do this every time!)
make bench-down
```

Estimated cost per scenario on on-demand c7g.large: **~$0.10 (scenario 01) / ~$0.17 (02) / ~$0.33 (03)**. Spot is roughly half, with the caveat below.

## Scenarios

- **01 — Fresh-handshake latency** → `scenarios/01-fresh-handshake-latency/`
  Classical vs PQ with a new TCP + TLS handshake per request. The scenario where PQ overhead is most visible.

- **02 — Session resumption** → `scenarios/02-resumption/`
  Fresh vs resumed handshake × classical vs PQ. 4 arms × 3 trials. Shows what happens when real-world connection pooling kicks in and the handshake is skipped.

- **03 — Payload size sweep** → `scenarios/03-payload-sweep/`
  Classical vs PQ at 100B / 10K / 100K response sizes, handshake amortized over 10 requests per connection. Measures record-layer-only PQ cost.

Per-phase execution playbooks live in `docs/`.

## Project structure

```
pqc-bench/
├── terraform/
│   ├── target/          # nginx-pq target module (OpenSSL 3.5, ML-DSA-65 cert)
│   ├── loadgen/         # Gatling loadgen module (OpenJDK 21 + Maven)
│   └── bench/           # Root module composing both
├── scenarios/
│   ├── 01-fresh-handshake-latency/
│   ├── 02-resumption/
│   └── 03-payload-sweep/
│       ├── gatling/     # Gatling simulation (Java)
│       └── run.sh       # Driver: apply tls_group, run, collect
├── analysis/            # Jupyter notebooks + parse_gatling.py
├── results/             # Raw Gatling output + rendered charts
├── docs/                # Phase walkthroughs, methodology
├── scripts/             # Helper scripts (SSH wrappers, log fetchers)
└── Makefile             # All commands live here
```

## Cost discipline

The number-one killer of this project's budget is forgotten instances. Rules:

1. **Always** `make bench-down` after any run. Set a daily calendar reminder for the first 30 days.
2. Set an AWS Budget alert at $10/month in the AWS console.
3. Never keep an Elastic IP allocated (this project doesn't need one).
4. **Spot is the default** (`var.use_spot = true`), matching Phase 1's cost promise. For long runs — scenario 03 is ~2h15m and I had the loadgen reclaimed mid-run — pass `-var "use_spot=false"` to switch to on-demand. On-demand is ~2x the hourly cost but will not interrupt.

## Status

- [x] Phase 0: Foundation (Terraform, user-data, Makefile, baked AMIs)
- [x] Phase 1: Fresh-handshake latency measured, Part 1 blog published
- [x] Phase 2: Session resumption + payload sweep measured, Part 2 blog drafted
- [ ] Phase 3: Cert-chain size impact (ML-DSA-65 ~3.3 kB vs ECDSA ~70 B at varying RTT)
- [ ] Phase 4: Cross-architecture comparison (c7g Graviton3 vs c7i Sapphire Rapids vs c6a AMD)
- [ ] Phase 5: Nightly regression detection via GitHub Actions
- [ ] Phase 6: Path B algorithms via `oqsprovider` (SLH-DSA, Falcon, HQC)

## License

Apache 2.0. See `LICENSE`.
# pqc-bench-slh-dsa
