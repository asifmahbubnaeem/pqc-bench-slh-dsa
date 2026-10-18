#!/usr/bin/env bash
# Scenario 02 driver: fresh handshake vs resumed handshake, classical vs PQ.
#
# 4 arms × N trials:
#   classical + fresh    (new TLS per request — same as Phase 1 scenario 01)
#   classical + resumed  (one TLS, then N requests per connection)
#   pq        + fresh
#   pq        + resumed
#
# Between tls_group swaps, terraform recreates the target. Fresh/resumed is
# just a client-side flag — no server reconfiguration needed (session cache
# is always on in Phase 2 user-data).
#
# Usage from project root:
#   ./scenarios/02-resumption/run.sh [rate] [trials] [requestsPerUser]
# Defaults: rate=300 trials=3 requestsPerUser=10

set -euo pipefail

RATE="${1:-300}"
TRIALS="${2:-3}"
REQS_PER_USER="${3:-10}"
MEASURE_SEC="${MEASURE_SEC:-300}"
WARMUP_SEC="${WARMUP_SEC:-30}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$PROJECT_ROOT/terraform/bench"
SCENARIO_DIR="$PROJECT_ROOT/scenarios/02-resumption"
RESULTS_DIR="$PROJECT_ROOT/results/$(date +%Y-%m-%d)-scenario-02-rate${RATE}"
KEY_FILE="${SSH_KEY:-$HOME/.ssh/pqc-bench-key.pem}"

mkdir -p "$RESULTS_DIR"
echo "==> Results dir: $RESULTS_DIR"

LOADGEN_IP=$(cd "$TF_DIR" && terraform output -raw loadgen_public_ip)
echo "==> Loadgen: $LOADGEN_IP"

# Upload both simulations (Phase 1's FreshHandshakeLatency reused for fresh arms)
echo "==> Uploading simulations"
ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$LOADGEN_IP" \
    "mkdir -p /opt/gatling/src/test/java/pqcbench"
scp -i "$KEY_FILE" -o StrictHostKeyChecking=no \
    "$SCENARIO_DIR/gatling/src/test/java/pqcbench/ResumedHandshake.java" \
    ubuntu@"$LOADGEN_IP":/opt/gatling/src/test/java/pqcbench/
# Also pull in Phase 1 fresh handshake simulation if it's in the scenario-01 dir
if [ -f "$PROJECT_ROOT/scenarios/01-fresh-handshake-latency/gatling/src/test/java/pqcbench/FreshHandshakeLatency.java" ]; then
    scp -i "$KEY_FILE" -o StrictHostKeyChecking=no \
        "$PROJECT_ROOT/scenarios/01-fresh-handshake-latency/gatling/src/test/java/pqcbench/FreshHandshakeLatency.java" \
        ubuntu@"$LOADGEN_IP":/opt/gatling/src/test/java/pqcbench/
fi

REMOTE_ENV='export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))'

run_arm() {
    local group="$1"       # X25519 or X25519MLKEM768
    local mode="$2"        # fresh or resumed
    local tag="$3"         # classical-fresh, classical-resumed, pq-fresh, pq-resumed
    local sim_class="$4"   # pqcbench.FreshHandshakeLatency or .ResumedHandshake
    local trials="$5"

    echo ""
    echo "=================================================================="
    echo "==> ARM: $tag  (Groups=$group, mode=$mode, sim=$sim_class)"
    echo "=================================================================="

    # Only re-apply terraform when tls_group changes (not for each mode)
    local current_group
    current_group=$(cd "$TF_DIR" && terraform output -raw target_tls_group 2>/dev/null || echo "")
    if [ "$current_group" != "$group" ]; then
        echo "==> terraform apply — tls_group=$group"
        (cd "$TF_DIR" && terraform apply -auto-approve -var "tls_group=$group" 2>&1 | tail -3)
        # Wait for new target to be ready
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
        echo "==> Reusing existing target (same tls_group)"
    fi

    TARGET_PRIV=$(cd "$TF_DIR" && terraform output -raw target_private_ip)

    for trial in $(seq 1 "$trials"); do
        echo "==> Trial $trial/$trials  arm=$tag"
        local trial_results="$RESULTS_DIR/$tag/trial-$trial"
        mkdir -p "$trial_results"

        ssh -i "$KEY_FILE" ubuntu@"$LOADGEN_IP" "
            $REMOTE_ENV
            cd /opt/gatling
            rm -rf target/gatling
            ./mvnw -B \
                -Dgatling.simulationClass=$sim_class \
                -Dtarget='https://$TARGET_PRIV:443' \
                -Drate=$RATE \
                -DmeasureSec=$MEASURE_SEC \
                -DwarmupSec=$WARMUP_SEC \
                -DrequestsPerUser=$REQS_PER_USER \
                -Dtag=$tag \
                -Dgatling.http.ssl.trustAll=true \
                gatling:test 2>&1 | tail -20
        "

        local sim_lc=$(echo "$sim_class" | awk -F. '{print tolower($NF)}')
        LATEST=$(ssh -i "$KEY_FILE" ubuntu@"$LOADGEN_IP" \
            "ls -td /opt/gatling/target/gatling/${sim_lc}-* 2>/dev/null | head -1")
        if [ -z "$LATEST" ]; then
            echo "!! No results"; continue
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
  "mode": "$mode",
  "sim_class": "$sim_class",
  "rate_users_per_sec": $RATE,
  "requests_per_user": $REQS_PER_USER,
  "measure_sec": $MEASURE_SEC,
  "warmup_sec": $WARMUP_SEC,
  "trial": $trial,
  "target_private_ip": "$TARGET_PRIV",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
META
        echo "==> Trial $trial done → $trial_results"
    done
}

echo ""
echo "==> Scenario 02 — session resumption"
echo "    rate=$RATE  requestsPerUser=$REQS_PER_USER  trials=$TRIALS/arm"

# Order chosen to minimize terraform re-applies: do both modes per tls_group
run_arm "X25519"         "fresh"   "classical-fresh"   "pqcbench.FreshHandshakeLatency" "$TRIALS"
run_arm "X25519"         "resumed" "classical-resumed" "pqcbench.ResumedHandshake"      "$TRIALS"
run_arm "X25519MLKEM768" "fresh"   "pq-fresh"          "pqcbench.FreshHandshakeLatency" "$TRIALS"
run_arm "X25519MLKEM768" "resumed" "pq-resumed"        "pqcbench.ResumedHandshake"      "$TRIALS"

echo ""
echo "=================================================================="
echo "==> Done. Results: $RESULTS_DIR"
echo "=================================================================="
find "$RESULTS_DIR" -name index.html | sed 's/^/    /'
