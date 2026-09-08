# Qwen 3.8 Flash-Next MTP benchmark report

**Date:** 2026-09-08  
**Endpoint:** `http://127.0.0.1:8080/v1`  
**Served model:** `qwen3.8-flash-next-mtp`

## Environment

| Item | Value |
|---|---|
| Host CPU / APU | AMD Ryzen AI MAX+ 395 |
| GPU | AMD Radeon 8060S (Strix Halo) |
| GPU driver / backend | `amdgpu` / Vulkan RADV |
| Container image | `drluoto-llamacpp:strix-halo-vulkan` |
| llama.cpp build | `0.3.0-dev`, build 10718, commit `ba5354d46` |
| llama.cpp source | `drluoto/llama.cpp`, branch `strix-halo-vulkan`, ref `ba5354d46ca63e8225c28e1331f0f7651723ad05` |
| llama-benchy | `0.4.0` |
| Tokenizer | `Qwen/Qwen3.8-Flash-Next` |

## llama.cpp arguments declared in `docker-compose.yaml`

The following is the complete `command:` passed to the container (the API-key value remains in the mounted secret and is not included here):

```text
llama-server
--api-key-file /run/secrets/qwen_api_key
-m /models/unsloth/Qwen3.8-Flash-Next-GGUF/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
-md /models/drluoto/Qwen3.8-Flash-Next-MTP-GGUF/mtp-Qwen3.8-Flash-Next-Q8_0-frspec-65k.gguf
--mmproj /models/unsloth/Qwen3.8-Flash-Next-GGUF/mmproj-BF16.gguf
--temperature 1.0
--top-k 20
--top-p 0.95
--min-p 0.0
--presence-penalty 0.0
--spec-type draft-mtp
--spec-draft-n-max 3
--spec-draft-p-min 0.0
-ngl 999
-fa on
-b 2048
-ub 2048
-c 264000
--parallel 2
--ctx-checkpoints 8
-ctk f16
-ctv f16
-lm dio
--jinja
--chat-template-file /models/froggeric/Qwen-Fixed-Chat-Templates/chat_template.jinja
--reasoning-format deepseek
--reasoning-preserve
--no-webui
--host 0.0.0.0
--port 8080
--alias qwen3.8-flash-next-mtp
```

The Compose service also sets `GGML_VK_DISABLE_GDN_CACHE_FUSION=1`, passes `/dev/dri`, uses `seccomp=unconfined`, and mounts `~/Models` read-only at `/models`.

## Benchmark methodology

Two clean llama-benchy sweeps were run independently, one at concurrency 1 and one at concurrency 2 (matching `--parallel 2`):

```text
uvx llama-benchy \
  --base-url http://127.0.0.1:8080/v1 \
  --model qwen3.8-flash-next-mtp \
  --tokenizer Qwen/Qwen3.8-Flash-Next \
  --pp 2048 --tg 128 \
  --depth 0 4096 8192 16384 32768 \
  --runs 3 --latency-mode generation \
  --no-cache --concurrency <1|2> \
  --format json
```

The server runs with `--spec-type draft-mtp --spec-draft-n-max 3`, so all measurements are taken with MTP speculative decoding active; llama-benchy handles multi-token MTP chunks natively. Server-side logs during these runs reported `draft acceptance` near 0.5 on the benchmark text.

`--no-cache` adds request noise and sends `cache-prompt=false`; therefore, these are uncached-context measurements. Each row is the mean ± population standard deviation of three measured runs after llama-benchy's one-run warmup. The generation latency probes measured 130.56 ms (c1) and 232.98 ms (c2), and llama-benchy subtracts this latency from TTFR to calculate estimated prompt-processing time.

**Columns:** PP = prompt-processing throughput; TG = generation throughput; peak TG = highest observed one-second generation window; TTFR = time to first response; est. PP = TTFR less measured latency; E2E TTFT = time to first content token. `t/s` is tokens per second and timing is milliseconds.

## Results — concurrency 1

| Context depth | PP t/s | TG t/s | Peak TG t/s | TTFR (ms) | Est. PP (ms) | E2E TTFT (ms) |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 573.73 ± 4.05 | 40.77 ± 1.92 | 41.67 ± 1.89 | 3,702.71 ± 25.40 | 3,572.16 ± 25.40 | 3,702.71 ± 25.40 |
| 4,096 | 527.26 ± 7.04 | 39.41 ± 3.52 | 39.67 ± 3.68 | 11,786.46 ± 154.01 | 11,655.91 ± 154.01 | 11,786.46 ± 154.01 |
| 8,192 | 508.04 ± 1.68 | 43.30 ± 2.90 | 43.67 ± 2.62 | 20,288.60 ± 66.40 | 20,158.05 ± 66.40 | 20,288.60 ± 66.40 |
| 16,384 | 469.28 ± 0.76 | 40.99 ± 2.03 | 41.33 ± 1.70 | 39,409.26 ± 64.30 | 39,278.71 ± 64.30 | 39,409.26 ± 64.30 |
| 32,768 | 408.31 ± 0.40 | 37.69 ± 1.28 | 38.33 ± 1.25 | 85,398.70 ± 85.32 | 85,268.15 ± 85.32 | 85,398.70 ± 85.32 |

## Extended results — concurrency 1

The current `--parallel 2` configuration gives each slot 132,096 tokens. The 128K run therefore remains below the per-slot context limit after allowing for the 2,048-token prompt, 128-token output, and chat-template overhead.

| Context depth | PP t/s | TG t/s | Peak TG t/s | TTFR (ms) | Est. PP (ms) | E2E TTFT (ms) |
|---:|---:|---:|---:|---:|---:|---:|
| 65,536 | 324.74 ± 0.89 | 31.69 ± 1.09 | 32.33 ± 0.94 | 208,254.78 ± 573.98 | 208,119.04 ± 573.98 | 208,254.78 ± 573.98 |
| 98,304 | 267.30 ± 1.76 | 27.39 ± 1.62 | 27.67 ± 1.70 | 375,578.95 ± 2,476.29 | 375,443.20 ± 2,476.29 | 375,578.95 ± 2,476.29 |
| 128,000 | 230.98 ± 0.30 | 25.49 ± 1.98 | 26.00 ± 2.16 | 563,177.03 ± 724.33 | 563,041.28 ± 724.33 | 563,177.03 ± 724.33 |

## Results — concurrency 2

For c2, `total` is aggregate throughput for both requests; `per request` is llama-benchy's average request throughput.

| Context depth | PP total / request (t/s) | TG total / request (t/s) | Peak TG total (t/s) | TTFR (ms) | Est. PP (ms) | E2E TTFT (ms) |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 538.52 ± 1.46 / 281.58 ± 3.90 | 43.10 ± 2.49 / 23.69 ± 2.33 | 48.33 ± 2.36 | 7,511.15 ± 100.81 | 7,278.17 ± 100.81 | 7,511.15 ± 100.81 |
| 4,096 | 518.00 ± 0.50 / 292.17 ± 30.60 | 25.76 ± 0.78 / 18.97 ± 5.87 | 39.33 ± 1.25 | 21,498.51 ± 2,227.11 | 21,265.53 ± 2,227.11 | 21,498.51 ± 2,227.11 |
| 8,192 | 502.70 ± 1.39 / 313.76 ± 60.97 | 13.68 ± 0.35 / 15.82 ± 9.02 | 32.67 ± 1.70 | 34,154.24 ± 6,591.28 | 33,921.26 ± 6,591.28 | 34,154.24 ± 6,591.28 |
| 16,384 | 466.63 ± 0.39 / 315.39 ± 81.38 | 6.65 ± 0.06 / 12.77 ± 9.48 | 26.67 ± 1.25 | 62,847.10 ± 16,157.18 | 62,614.12 ± 16,157.18 | 62,847.10 ± 16,157.18 |
| 32,768 | 411.41 ± 0.77 / 290.85 ± 84.86 | 3.10 ± 0.02 / 12.02 ± 10.47 | 25.00 ± 0.82 | 131,080.14 ± 38,177.85 | 130,847.17 ± 38,177.85 | 131,080.14 ± 38,177.85 |

## Notes

- All three committed sweeps passed llama-benchy's coherence check. The c1 and c2 sweeps cover five depths through 32K; the extended c1 sweep covers 64K, 96K and 128K. The endpoint was healthy after every run.
- An earlier combined c1/c2 attempt, run without `--no-cache`, completed c1 through 8K but hit transfer/connection failures during the 8K c2 workload, and the server restarted before the deeper cases ran. Its output is not committed: the rows past 8K are empty and must not be read as results. The `*-no-cache` files listed under "Raw artifacts" are the authoritative set.
- At c2, context processing remains near 411–539 aggregate t/s, but decode latency becomes highly variable at longer contexts. Use the c2 per-request metrics and their standard deviations when evaluating interactive two-user behaviour.

## Raw artifacts

- `results/retry-c1-no-cache.json` — authoritative concurrency-1 structured results.
- `results/retry-c1-no-cache.log` — concurrency-1 run log.
- `results/retry-c2-no-cache.json` — authoritative concurrency-2 structured results.
- `results/retry-c2-no-cache.log` — concurrency-2 run log.
- `results/extended-c1-128k-no-cache.json` — authoritative 64K/96K/128K concurrency-1 results.
- `results/extended-c1-128k-no-cache.log` — extended concurrency-1 run log.
