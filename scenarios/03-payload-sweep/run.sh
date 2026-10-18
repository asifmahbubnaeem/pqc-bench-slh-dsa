#!/usr/bin/env bash
# Scenario 03 driver: payload-size sweep × classical vs PQ.
#
# 8 arms × N trials:
#   classical-100B   classical-10K   classical-100K   classical-1M
#   pq-100B          pq-10K          pq-100K          pq-1M
#
# Uses resumed-handshake pattern (shareConnections) so the handshake
# amortizes over requestsPerUser — the signal is bulk/record-layer cost
# across payload sizes, not the handshake. For raw handshake cost see 02.
#
# Payloads are pre-generated on the target in /var/www/pqc-bench/*.bin
# and served via sendfile (see user-data-fast.sh.tftpl).
#
# Usage from project root:
#   ./scenarios/03-payload-sweep/run.sh [rate] [trials] [requestsPerUser]
# Defaults: rate=200 trials=3 requestsPerUser=10

set -euo pipefail

RATE="${1:-200}"
TRIALS="${2:-3}"
REQS_PER_USER="${3:-10}"
MEASURE_SEC="${MEASURE_SEC:-300}"
WARMUP_SEC="${WARMUP_SEC:-30}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$PROJECT_ROOT/terraform/bench"
SCENARIO_DIR="$PROJECT_ROOT/scenarios/03-payload-sweep"
RESULTS_DIR="$PROJECT_ROOT/results/$(date +%Y-%m-%d)-scenario-03-rate${RATE}"
KEY_FILE="${SSH_KEY:-$HOME/.ssh/pqc-bench-key.pem}"

PAYLOADS=("100B" "10K" "100K" "1M")

mkdir -p "$RESULTS_DIR"
echo "==> Results dir: $RESULTS_DIR"

LOADGEN_IP=$(cd "$TF_DIR" && terraform output -raw loadgen_public_ip)
echo "==> Loadgen: $LOADGEN_IP"

echo "==> Uploading simulation"
ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$LOADGEN_IP" \
    "mkdir -p /opt/gatling/src/test/java/pqcbench"
scp -i "$KEY_FILE" -o StrictHostKeyChecking=no \
    "$SCENARIO_DIR/gatling/src/test/java/pqcbench/PayloadSweep.java" \
    ubuntu@"$LOADGEN_IP":/opt/gatling/src/test/java/pqcbench/

REMOTE_ENV='export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))'

ensure_group() {
    local group="$1"
    local current_group
    current_group=$(cd "$TF_DIR" && terraform output -raw target_tls_group 2>/dev/null || echo "")
    if [ "$current_group" != "$group" ]; then
        echo "==> terraform apply — tls_group=$group"
        (cd "$TF_DIR" && terraform apply -auto-approve -var "tls_group=$group" 2>&1 | tail -3)
        TARGET_IP=$(cd "$TF_DIR" && terraform output -raw target_public_ip)
        echo "==> Waiting for target readiness"
        for i in $(seq 1 30); do
            if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_FILE" \
                 ubuntu@"$TARGET_IP" "test -f /var/lib/pqc-bench-ready" 2>/dev/null; then
                echo "==> Target ready after $((i*5))s"; break
            fi
            sleep 5
        done
    else
        echo "==> Reusing existing target (same tls_group=$group)"
    fi
}

run_payload_trial() {
    local group="$1"       # X25519 or X25519MLKEM768
    local arm="$2"         # classical or pq
    local payload="$3"     # 100B, 10K, 100K, 1M
    local trial="$4"

    local tag="${arm}-${payload}"
    local target_priv
    target_priv=$(cd "$TF_DIR" && terraform output -raw target_private_ip)

    local trial_results="$RESULTS_DIR/$tag/trial-$trial"
    mkdir -p "$trial_results"

    echo "==> Trial $trial  arm=$tag  (target=$target_priv)"

    ssh -i "$KEY_FILE" ubuntu@"$LOADGEN_IP" "
        $REMOTE_ENV
        cd /opt/gatling
        rm -rf target/gatling
        ./mvnw -B \
            -Dgatling.simulationClass=pqcbench.PayloadSweep \
            -Dtarget='https://$target_priv:443' \
            -Dpayload=$payload \
            -Drate=$RATE \
            -DmeasureSec=$MEASURE_SEC \
            -DwarmupSec=$WARMUP_SEC \
            -DrequestsPerUser=$REQS_PER_USER \
            -Dtag=$tag \
            -Dgatling.http.ssl.trustAll=true \
            gatling:test 2>&1 | tail -20
    "

    LATEST=$(ssh -i "$KEY_FILE" ubuntu@"$LOADGEN_IP" \
        "ls -td /opt/gatling/target/gatling/payloadsweep-* 2>/dev/null | head -1")
    if [ -z "$LATEST" ]; then
        echo "!! No results"; return
    fi
    pulled=false
    for attempt in 1 2 3; do
        if scp -qr -i "$KEY_FILE" \
             -o ServerAliveInterval=15 -o ServerAliveCountMax=20 -o ConnectTimeout=30 \
             ubuntu@"$LOADGEN_IP":"$LATEST"/* "$trial_results/" 2>/dev/null; then
            pulled=true; break
        fi
        echo "!! scp attempt $attempt failed; retry in 10s"; sleep 10
    done
    if ! $pulled; then
        echo "!! WARN: could not pull $tag trial $trial — raw on loadgen: $LATEST"
        continue
    fi

    cat > "$trial_results/meta.json" <<META
{
  "arm": "$tag",
  "tls_group": "$group",
  "payload": "$payload",
  "rate_users_per_sec": $RATE,
  "requests_per_user": $REQS_PER_USER,
  "measure_sec": $MEASURE_SEC,
  "warmup_sec": $WARMUP_SEC,
  "trial": $trial,
  "target_private_ip": "$target_priv",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
META
    echo "==> Trial done → $trial_results"
}

echo ""
echo "==> Scenario 03 — payload size sweep"
echo "    rate=$RATE  requestsPerUser=$REQS_PER_USER  trials=$TRIALS/arm"
echo "    payloads: ${PAYLOADS[*]}"
echo "    arms: 2 groups × 4 payloads × $TRIALS trials = $((2 * 4 * TRIALS)) runs"

# Order: do all 4 payloads for one tls_group, then swap groups once.
# Each group swap costs ~2 min of terraform apply + target boot.
for group_arm in "X25519:classical" "X25519MLKEM768:pq"; do
    IFS=":" read -r group arm <<< "$group_arm"
    echo ""
    echo "=================================================================="
    echo "==> GROUP: $group ($arm)"
    echo "=================================================================="
    ensure_group "$group"

    for payload in "${PAYLOADS[@]}"; do
        for trial in $(seq 1 "$TRIALS"); do
            run_payload_trial "$group" "$arm" "$payload" "$trial"
        done
    done
done

echo ""
echo "=================================================================="
echo "==> Done. Results: $RESULTS_DIR"
echo "=================================================================="
find "$RESULTS_DIR" -name index.html | sed 's/^/    /'
