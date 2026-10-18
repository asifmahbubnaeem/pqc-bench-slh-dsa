#!/usr/bin/env bash
# Runs openssl 3.5 s_time against the target for one trial.
# Lives on the loadgen (uploaded by run.sh); invoked over SSH.
#
# Why not Gatling?
#   JDK 21's X509 parser rejects ML-DSA-65 public key OIDs during TLS
#   handshake, before any trustAll check fires. OpenSSL 3.5 is the only
#   client-side TLS stack we have that speaks all three cert sig algs we're
#   measuring (ECDSA / RSA / ML-DSA), so scenario 04 uses it directly.
#
# Trade-off: s_time gives aggregate stats only (count × wall time →
# average), no per-handshake percentiles. For cert-size × RTT the headline
# is mean delta anyway (every handshake pays the same extra round-trip),
# so this is acceptable.
#
# Usage:
#   handshake-bench.sh <target_ip> <duration_sec>
# Outputs (stdout):
#   connections=NNN
#   wall_seconds=NN.NN
#   avg_ms_per_handshake=NN.NNN
#   rate_hs_per_sec=NN.NN
# Full openssl output goes to stderr for debugging.

set -uo pipefail

TARGET="${1:?usage: handshake-bench.sh <target_ip> <duration_sec>}"
DURATION="${2:?usage: handshake-bench.sh <target_ip> <duration_sec>}"

OSSL=/opt/openssl-3.5/bin/openssl
[ -x "$OSSL" ] || { echo "ERROR: $OSSL not found/executable" >&2; exit 2; }

# -new : only new sessions, no resumption (fresh handshake every time)
# -time: cycle duration in seconds
# -verify 0: skip verification depth check (we have self-signed certs)
# -connect: target
# -www /: send a minimal GET so the server completes the response quickly
OUTPUT=$("$OSSL" s_time \
    -connect "$TARGET:443" \
    -new \
    -time "$DURATION" \
    -www / \
    2>&1)

# Dump full output on stderr for debugging and audit trail
echo "$OUTPUT" >&2
echo "----" >&2

# s_time output includes a line like:
#   "N connections in M real seconds, X bytes read per connection"
# Prefer that; fall back to the "connections/user sec" line if "real" isn't present.
LINE=$(echo "$OUTPUT" | grep -E '[0-9]+ connections in [0-9.]+ real seconds' | tail -1)
if [ -n "$LINE" ]; then
    CONN_COUNT=$(echo "$LINE" | awk '{print $1}')
    WALL_SEC=$(echo   "$LINE" | awk '{print $4}')
else
    # Fallback — some openssl builds say "N connections in Ts" (just s)
    LINE=$(echo "$OUTPUT" | grep -E '[0-9]+ connections in [0-9.]+s;' | tail -1)
    [ -z "$LINE" ] && { echo "ERROR: could not parse any s_time connections line" >&2; echo "===" >&2; echo "$OUTPUT" >&2; exit 3; }
    CONN_COUNT=$(echo "$LINE" | awk '{print $1}')
    WALL_SEC=$(echo "$LINE" | awk '{print $4}' | tr -d 's;')
fi

if [ -z "$CONN_COUNT" ] || [ -z "$WALL_SEC" ] || [ "$CONN_COUNT" = "0" ]; then
    echo "ERROR: zero/empty connection count or wall time (count=$CONN_COUNT, wall=$WALL_SEC)" >&2
    exit 4
fi

# Compute derived stats
AVG_MS=$(python3 -c "print(f'{float($WALL_SEC) / float($CONN_COUNT) * 1000:.3f}')" 2>/dev/null || \
         awk "BEGIN { printf \"%.3f\", $WALL_SEC / $CONN_COUNT * 1000 }")
RATE=$(python3 -c "print(f'{float($CONN_COUNT) / float($WALL_SEC):.2f}')" 2>/dev/null || \
       awk "BEGIN { printf \"%.2f\", $CONN_COUNT / $WALL_SEC }")

cat <<EOF
connections=$CONN_COUNT
wall_seconds=$WALL_SEC
avg_ms_per_handshake=$AVG_MS
rate_hs_per_sec=$RATE
EOF
