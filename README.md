# Qwen 3.8 Flash-Next on Strix Halo

Docker Compose setup for serving Qwen 3.8 Flash-Next on an AMD Strix Halo box
(Ryzen AI MAX+ 395 / Radeon 8060S) using
[EngramHalo.cpp](https://github.com/Aristo94/EngramHalo.cpp) — a patched
llama.cpp branch with a working MTP draft head and an SSD-backed engram table.

The repo is just the deployment config: three `llama-server` profiles
(ROCm, Vulkan, a short-context "fast" variant), the download commands for the
weights, and the benchmark scripts. The engine itself lives upstream.

![Docker](https://img.shields.io/badge/Docker-compose%20profiles-2496ED?logo=docker&logoColor=white)

## What is in here

| Path | What it does |
|---|---|
| `docker-compose.yaml` | Three `llama-server` profiles: `long` (ROCm, 128K), `fast`, `vulkan` |
| `EngramHalo.cpp/` | Clone of the tuned llama.cpp branch — build context for the images (gitignored) |
| `drluoto/` | Vulkan image for [drluoto/llama.cpp](https://github.com/drluoto/llama.cpp) `strix-halo-vulkan`, plus the MTP workload replay |
| `benchmarks/` | `perfbench.py` and the A/B test plan (gitignored) |
| `.api-key` | Server API key, mounted read-only as a compose secret (gitignored) |

Default profile runs 128K context, MTP + n-gram speculative decoding, Q8 KV
cache, and the 26.8 GiB engram table on NVMe via `mmap` — roughly 1 GiB
resident instead of 26.8 GiB pinned.

## Prerequisites

- AMD Strix Halo (Ryzen AI MAX+ 395 / Radeon 8060S, `gfx1151`), 128 GB unified
  memory. The 96 GB variant works with smaller kernel/GTT limits — see the
  upstream [Strix Halo notes](https://github.com/Aristo94/EngramHalo.cpp/tree/strix-halo-qwen4exp/docs/strix-halo).
- ~100 GB free NVMe for the GGUFs. Put them on your fastest drive: the engram
  table is read straight off these files.
- Docker Engine with the Compose plugin, and the `hf` (Hugging Face) CLI.
- Kernel args for the GTT aperture, in `/etc/default/grub` (values below are
  for the 128 GB host):

  ```text
  amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
  ```

## Setting up

**1. Clone the tuned fork into this directory.** It is the build context for
both images, and must sit at `./EngramHalo.cpp`.

```sh
git clone \
  --branch strix-halo-qwen4exp \
  https://github.com/Aristo94/EngramHalo.cpp.git
```

**2. Create the API key.**

```sh
umask 077 && openssl rand -base64 48 > .api-key
```

**3. Pull the weights (~100 GB).** They land under `~/Models`, which the
compose file mounts read-only at `/models`. Keep the directory layout as
written — the server command lines reference these exact paths.

```sh
mkdir -p ~/Models && cd ~/Models

# main model, IQ4_XS (3 shards, ~93 GB)
hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  --local-dir unsloth/Qwen3.8-Flash-Next-GGUF \
  --include "*UD-IQ4_XS*"

# MTP draft head
hf download EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF \
  mtp-Qwen3.8-Flash-Next-Q8_0.gguf \
  --local-dir EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF

# FR-Spec MTP head, only needed for the `drluoto` profile (3.64 GB)
hf download drluoto/Qwen3.8-Flash-Next-MTP-GGUF \
  mtp-Qwen3.8-Flash-Next-Q8_0-frspec-65k.gguf \
  --local-dir drluoto/Qwen3.8-Flash-Next-MTP-GGUF

# vision head
hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  mmproj-BF16.gguf \
  --local-dir unsloth/Qwen3.8-Flash-Next-GGUF
```

Expected result:

```text
~/Models
├── EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF/mtp-Qwen3.8-Flash-Next-Q8_0.gguf
├── drluoto/Qwen3.8-Flash-Next-MTP-GGUF/mtp-Qwen3.8-Flash-Next-Q8_0-frspec-65k.gguf
└── unsloth/Qwen3.8-Flash-Next-GGUF
    ├── mmproj-BF16.gguf
    └── UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-0000{1,2,3}-of-00003.gguf
```

## Running the project

Build and start the default (ROCm, 128K) profile. The first build compiles
llama.cpp against ROCm 7.14 and takes a while; later starts reuse the image.

```sh
docker compose --profile long up -d
docker logs -f qwen38-flash-next-qwen-long-1
```

Wait for `server_ready` in the log, then check it answers:

```sh
curl -s -H "Authorization: Bearer $(cat .api-key)" \
  http://127.0.0.1:8080/v1/models

curl -s -H "Authorization: Bearer $(cat .api-key)" \
  -H 'Content-Type: application/json' \
  http://127.0.0.1:8080/v1/chat/completions \
  -d '{
    "model": "qwen3.8-flash-next",
    "messages": [{"role": "user", "content": "Hello"}],
    "temperature": 0
  }'
```

Point any OpenAI-compatible client at `http://<host>:8080/v1` with the model
name `qwen3.8-flash-next`.

Other profiles:

```sh
docker compose --profile fast up -d     # 32K context, engram table in RAM
docker compose --profile vulkan up -d   # Vulkan/RADV build
docker compose down                     # stop
```

## The MTP benchmark profile

The MTP head this profile serves —
[`drluoto/Qwen3.8-Flash-Next-MTP-GGUF`](https://huggingface.co/drluoto/Qwen3.8-Flash-Next-MTP-GGUF)
— is an FR-Spec draft: its output vocabulary is trimmed to 65,536
frequency-ranked rows with a `d2t` map back to real token ids, and only
[drluoto/llama.cpp](https://github.com/drluoto/llama.cpp) `strix-halo-vulkan`
reads that layout. Neither EngramHalo.cpp nor stock llama.cpp can load it, so
this profile does not use the `EngramHalo.cpp` build context at all — it builds
its own image from `drluoto/Dockerfile`, pinned to `ba5354d46`. Upstream puts it
plainly: the draft head "needs this branch; stock llama.cpp will not load it".

```sh
docker compose --profile drluoto up -d --build
curl -s http://127.0.0.1:8081/health
```

This profile is the benchmark configuration, not a production tuning: MTP only
(`--spec-type draft-mtp`), three draft tokens, no draft probability floor,
full-precision F16 K/V, 262,144-token context across three slots, and
`-lm dio`. It listens on `127.0.0.1:8081` without an API key, so replaying the
workloads needs no extra header; add `--api-key-file` before exposing it.

Reproduce the measurement with the workload replay baked into the image:

```sh
./drluoto/run-bench.sh        # six workloads, plus memory sampling
```

## MTP results

One pass of the six-workload replay against the profile flags, on a host build
of `ba5354d46` (Vulkan, Mesa 26.2.1, `GGML_VK_DISABLE_GDN_CACHE_FUSION=1`),
greedy sampling, `cache_prompt: false`. These are server-reported timings, not
repeated runs. Acceptance counts accepted draft tokens over drafted tokens;
`--spec-draft-p-min 0.0` puts no probability floor under a draft.

| Workload | Prompt tokens | Prefill | Decode | Tokens/step | Acceptance |
|---|---:|---:|---:|---:|---:|
| short code @0 | 39 | 103.0 | 55.8 | 3.66 | 0.90 |
| new code @8k | 8,210 | 565.2 | 50.1 | 3.53 | 0.85 |
| prose @8k | 8,221 | 558.0 | 31.2 | 2.20 | 0.40 |
| file rewrite @8k | 8,362 | 531.1 | 52.4 | 3.97 | 1.00 |
| new code @32k | 32,763 | 430.8 | 35.8 | 2.89 | 0.64 |
| file rewrite @32k | 32,314 | 446.3 | 48.0 | 3.97 | 1.00 |

The same shards without a draft head decoded at 28.28 tokens/s
(`llama-bench`, tg128), so MTP is worth about 1.1x to 2.0x here: it pays when
the output is structured or copied, and prose barely clears the verification
cost. Memory across the run averaged 109.15 GiB and peaked at 118.32 GiB
(`MemTotal - MemAvailable`, a combined CPU+GPU figure on this unified-memory
board).

`./drluoto/run-bench.sh` replays the same suite against the container; the
container itself has not been timed separately from the host run.

## Notes and limitations

- Tuned and measured on ROCm/HIP only. The upstream docs report the Vulkan
  path as a net loss versus a stock build on RADV; the `vulkan` profile exists
  and builds, but is untested here.
- `--parallel 2` is what this box is validated on. The MTP / sparse-gather path
  is best validated at low concurrency.
- `-lm mmap` is load-bearing for 128K context. Never add `--no-mmap`: it
  silently disables the lazy-read path and pins the whole table.
- Specs and tuning flags in `docker-compose.yaml` are tuned for one machine
  (128 GB, NVMe, CPU governor `powersave`). Retune before trusting the numbers
  elsewhere.
- `benchmarks/` and `EngramHalo.cpp/` are gitignored, so a fresh clone needs
  step 1 above before any compose command will build. The `drluoto` profile is
  the exception: it clones its engine inside the image and needs nothing on
  disk but the weights.
- The `drluoto` profile pins a fork commit (`ba5354d46`), not the EngramHalo
  engine, and it is the only place the FR-Spec draft head loads. Two flags are
  load-bearing there: `GGML_VK_DISABLE_GDN_CACHE_FUSION=1` sidesteps a fused
  state-cache kernel that corrupts output on the 8060S, and `-lm dio` wants a
  filesystem with `O_DIRECT` (local ext4/NVMe — not a network mount).
- The `drluoto` profile serves unauthenticated on `127.0.0.1:8081` because that
  is how the benchmark was run. Do not republish it on a LAN address without
  adding `--api-key-file`.

## Acknowledgements

- [Aristo94/EngramHalo.cpp](https://github.com/Aristo94/EngramHalo.cpp) — the
  Strix Halo patch series and the
  [setup docs](https://github.com/Aristo94/EngramHalo.cpp/tree/strix-halo-qwen4exp/docs/strix-halo)
  this config follows.
- [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
  — model and mmproj.
- [EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF](https://huggingface.co/EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF)
  — prebuilt MTP sidecar.
