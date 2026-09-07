#!/usr/bin/env bash
set -Eeuo pipefail

# Replay the six MTP workloads against the running qwen-drluoto-mtp service and
# sample memory while they run. This is the measurement behind the MTP table in
# README.md: llama-bench has no speculative-decoding mode, so the numbers come
# from llama.cpp's own workload replay (spektrum.py, baked into the image at
# /opt/bench/spektrum.py), which reports per-workload decode speed and draft
# acceptance.
#
#   docker compose --profile drluoto up -d
#   ./drluoto/run-bench.sh
#   ./drluoto/run-bench.sh --interval 5    # memory sample every 5s (default 2)
#
# Output: benchmarks/drluoto-<stamp>/{spektrum.log,memory.csv}

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SVC="qwen-drluoto-mtp"
PROFILE="drluoto"
HOST_PORT=8081                       # loopback publish made by docker-compose.yaml
INTERVAL=2

while (($#)); do
  case "$1" in
    --interval) INTERVAL="${2:?missing value for --interval}"; shift 2 ;;
    -h|--help)  sed -n '3,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="benchmarks/drluoto-$STAMP"
mkdir -p "$OUT_DIR"

if ! docker compose --profile "$PROFILE" ps --status running --services 2>/dev/null |
     grep -qx "$SVC"; then
  echo "$SVC is not running. Start it with:" >&2
  echo "  docker compose --profile $PROFILE up -d" >&2
  exit 1
fi

# The model is ~90 GiB: give the load up to 15 minutes before giving up.
echo "Waiting for $SVC /health on 127.0.0.1:$HOST_PORT ..."
ready=0
for _ in $(seq 1 180); do
  if curl -sf "http://127.0.0.1:$HOST_PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done
if [[ "${ready:-0}" != 1 ]]; then
  echo "Server never became healthy — see: docker compose --profile $PROFILE logs $SVC" >&2
  exit 1
fi

# On a unified-memory host MemAvailable is the combined GPU + system figure.
printf 'ts,mem_available_kib\n' > "$OUT_DIR/memory.csv"
while :; do
  awk '/^MemAvailable:/ { printf "%s,%s\n", strftime("%s"), $2 }' /proc/meminfo >> "$OUT_DIR/memory.csv"
  sleep "$INTERVAL"
done &
SAMPLER=$!
trap 'kill "$SAMPLER" 2>/dev/null || true' EXIT

docker compose --profile "$PROFILE" exec -T "$SVC" \
  python3 /opt/bench/spektrum.py 2>&1 | tee "$OUT_DIR/spektrum.log"

kill "$SAMPLER" 2>/dev/null || true
trap - EXIT

awk -F, 'NR > 1 { s += $2; n++; if (min == "" || $2 < min) min = $2 }
         END {
           if (n) printf "\nmemory available: mean %.2f GiB, min %.2f GiB over %d samples\n",
                     s/n/1048576, min/1048576, n
         }' "$OUT_DIR/memory.csv"
echo "Logs: $OUT_DIR"
