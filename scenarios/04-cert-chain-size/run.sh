#!/usr/bin/env bash
# Scenario 04 driver (openssl variant): cert-chain size × fresh handshake.
#
# Replaces the Gatling-based run.sh after we discovered JDK 21 can't parse
# ML-DSA-65 public key OIDs. OpenSSL 3.5 (installed on the loadgen AMI)
# is the only client-side TLS stack we have that speaks all 3 sig algs.
#
# For each cert_type ∈ {ecdsa, rsa-2048, ml-dsa-65}:
#   terraform apply if needed (target gets replaced on cert_type change)
#   run openssl s_time for $DURATION seconds, N trials, pull stats.
#
# Usage from project root:
#   ./scenarios/04-cert-chain-size/run.sh [duration_sec] [trials]
# Defaults: duration=60 trials=3

set -uo pipefail

DURATION="${1:-60}"
TRIALS="${2:-3}"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$PROJECT_ROOT/terraform/phase-3"
SCENARIO_DIR="$PROJECT_ROOT/scenarios/04-cert-chain-size"
RESULTS_DIR="$PROJECT_ROOT/results/$(date +%Y-%m-%d)-scenario-04-openssl"
KEY_FILE="${SSH_KEY:-$HOME/.ssh/pqc-bench-key.pem}"

CERT_TYPES=("ml-dsa-65" "slh-dsa-128f")

mkdir -p "$RESULTS_DIR"
echo "==> Results dir: $RESULTS_DIR"

LOADGEN_IP=$(cd "$TF_DIR" && terraform output -raw loadgen_public_ip)
LOADGEN_REGION=$(cd "$TF_DIR" && terraform output -raw loadgen_region)
echo "==> Loadgen: $LOADGEN_IP ($LOADGEN_REGION)"

# Measure actual RTT once, log it for the record
TARGET_PUBLIC_IP=$(cd "$TF_DIR" && terraform output -raw target_public_ip)
echo "==> Probing RTT loadgen($LOADGEN_REGION) → target(us-east-1)"
RTT_SAMPLE=$(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$LOADGEN_IP" \
    "ping -c 10 -q $TARGET_PUBLIC_IP 2>/dev/null | tail -2 | head -1")
echo "    $RTT_SAMPLE"
echo "$LOADGEN_REGION,$RTT_SAMPLE" > "$RESULTS_DIR/rtt-probe-$LOADGEN_REGION.txt"

# Upload handshake-bench.sh to loadgen
echo "==> Uploading handshake-bench.sh"
scp -q -i "$KEY_FILE" -o StrictHostKeyChecking=no \
    "$SCENARIO_DIR/handshake-bench.sh" \
    ubuntu@"$LOADGEN_IP":/tmp/handshake-bench.sh
ssh -i "$KEY_FILE" ubuntu@"$LOADGEN_IP" "chmod +x /tmp/handshake-bench.sh"

run_cert_arm() {
    local cert_type="$1"
    local tag="${cert_type}-${LOADGEN_REGION}"

    echo ""
    echo "=================================================================="
    echo "==> ARM: $tag"
    echo "=================================================================="

    # Swap cert_type if needed (target gets replaced)
    local current_cert
    current_cert=$(cd "$TF_DIR" && terraform output -raw target_cert_type 2>/dev/null || echo "")
    if [ "$current_cert" != "$cert_type" ]; then
        echo "==> terraform apply — cert_type=$cert_type (loadgen_region=$LOADGEN_REGION)"
        (cd "$TF_DIR" && terraform apply -auto-approve \
            -var "loadgen_region=$LOADGEN_REGION" \
            -var "cert_type=$cert_type" 2>&1 | tail -5)

        local target_ip
        target_ip=$(cd "$TF_DIR" && terraform output -raw target_public_ip)
        echo "==> Waiting for target readiness ($target_ip)"
        for i in $(seq 1 30); do
            if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_FILE" \
                 ubuntu@"$target_ip" "test -f /var/lib/pqc-bench-ready" 2>/dev/null; then
                echo "==> Target ready after $((i*5))s"; break
            fi
            sleep 5
        done
    else
        echo "==> Reusing existing target (same cert_type=$cert_type)"
    fi

    local target_ip
    target_ip=$(cd "$TF_DIR" && terraform output -raw target_public_ip)

    for trial in $(seq 1 "$TRIALS"); do
        echo ""
        echo "==> $tag trial $trial/$TRIALS  target=$target_ip  duration=${DURATION}s"
        local trial_dir="$RESULTS_DIR/$tag/trial-$trial"
        mkdir -p "$trial_dir"

        # Run handshake-bench on loadgen, capture stats to stdout and openssl log to stderr
        if ssh -i "$KEY_FILE" -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
             ubuntu@"$LOADGEN_IP" \
             "/tmp/handshake-bench.sh $target_ip $DURATION" \
             > "$trial_dir/stats.txt" 2> "$trial_dir/openssl.log"; then
            echo "==> Stats:"
            sed 's/^/    /' "$trial_dir/stats.txt"
        else
            echo "!! handshake-bench failed for $tag trial $trial"
            echo "!! last 10 lines of openssl.log:"
            tail -10 "$trial_dir/openssl.log" | sed 's/^/    /'
            continue
        fi

        cat > "$trial_dir/meta.json" <<META
{
  "arm": "$tag",
  "cert_type": "$cert_type",
  "loadgen_region": "$LOADGEN_REGION",
  "target_public_ip": "$target_ip",
  "duration_sec": $DURATION,
  "trial": $trial,
  "tool": "openssl-3.5-s_time",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
META
    done
}

echo ""
echo "==> Scenario 04 — cert-chain size (openssl s_time)"
echo "    region=$LOADGEN_REGION  duration=${DURATION}s  trials=$TRIALS/arm"
echo "    arms: ${CERT_TYPES[*]} (${#CERT_TYPES[@]} arms × $TRIALS trials = $((${#CERT_TYPES[@]} * TRIALS)) runs)"
echo "    expected wall time: ~$((${#CERT_TYPES[@]} * TRIALS * DURATION / 60 + ${#CERT_TYPES[@]} * 2)) min including terraform swaps"
for cert_type in "${CERT_TYPES[@]}"; do
    run_cert_arm "$cert_type"
done

echo ""
echo "=================================================================="
echo "==> Done. Results: $RESULTS_DIR"
echo "=================================================================="
find "$RESULTS_DIR" -name stats.txt | sed 's/^/    /'
echo ""
echo "==> Quick summary:"
for arm_dir in "$RESULTS_DIR"/*/; do
    arm=$(basename "$arm_dir")
    [ -d "$arm_dir" ] || continue
    [ "$arm" = "rtt-probe-$LOADGEN_REGION.txt" ] && continue
    echo "  $arm:"
    for trial_dir in "$arm_dir"/trial-*/; do
        [ -f "$trial_dir/stats.txt" ] || continue
        avg=$(grep '^avg_ms_per_handshake=' "$trial_dir/stats.txt" | cut -d= -f2)
        echo "    $(basename $trial_dir)  avg=${avg}ms"
    done
done
