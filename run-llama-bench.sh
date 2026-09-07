#!/usr/bin/env bash
set -Eeuo pipefail

# Benchmark the same GGUF and GPU/runtime settings used by qwen-long.
# The running llama-server must be stopped first; use --stop-server to do that
# and restart it automatically after the benchmark.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="$ROOT_DIR/benchmarks"
IMAGE="engramhalo:qwen38-flash-rocm-7.14"
CONTAINER="qwen38-flash-next-qwen-long-1"
REPS=3
STOP_SERVER=0

usage() {
  cat <<'EOF'
Usage: ./run-llama-bench.sh [--stop-server] [--repetitions N]

Runs llama-bench in the Qwen ROCm image against the deployed IQ4_XS model.
Results are written to benchmarks/<timestamp>.jsonl and .stderr.log.

--stop-server       stop the active qwen-long container, then restart it
                    after benchmarking (required for a clean GPU measurement)
--repetitions N     llama-bench repetitions (default: 3)
EOF
}

while (($#)); do
  case "$1" in
    --stop-server) STOP_SERVER=1; shift ;;
    --repetitions) REPS="${2:?missing value for --repetitions}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "$RESULT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$RESULT_DIR/$STAMP.jsonl"
ERR="$RESULT_DIR/$STAMP.stderr.log"
RESTART=0

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  if (( ! STOP_SERVER )); then
    echo "Container $CONTAINER is running. Stop it first or rerun with --stop-server." >&2
    exit 1
  fi
  docker stop "$CONTAINER" >/dev/null
  RESTART=1
fi

cleanup() {
  if (( RESTART )); then
    (cd "$ROOT_DIR" && docker compose --profile long up -d qwen-long >/dev/null)
    echo "Restarted $CONTAINER"
  fi
}
trap cleanup EXIT

# Keep this aligned with docker-compose.yaml. llama-bench does not benchmark
# server-side MTP/Engram speculative decoding, so this measures base pp/tg.
docker run --rm \
  --name "qwen38-llama-bench-$STAMP" \
  --device /dev/kfd --device /dev/dri \
  --security-opt seccomp=unconfined \
  --env ROCBLAS_USE_HIPBLASLT=1 \
  --volume "$HOME/Models:/models:ro" \
  --entrypoint /usr/local/bin/llama-bench "$IMAGE" \
  --offline \
  --model /models/unsloth/Qwen3.8-Flash-Next-GGUF/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  --n-gpu-layers 999 \
  --lazy-mode on \
  --flash-attn on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --load-mode mmap \
  --batch-size 8192 --ubatch-size 2048 --threads 4 \
  --n-prompt 512,2048,8192 --n-gen 128 \
  --repetitions "$REPS" --output jsonl \
  >"$OUT" 2>"$ERR"

echo "Benchmark written to: $OUT"
echo "Diagnostics written to: $ERR"
