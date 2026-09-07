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

# vision head
hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  mmproj-BF16.gguf \
  --local-dir unsloth/Qwen3.8-Flash-Next-GGUF
```

Expected result:

```text
~/Models
├── EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF/mtp-Qwen3.8-Flash-Next-Q8_0.gguf
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

## Benchmarks

Measured on the configured AMD Radeon 8060S / Ryzen AI MAX+ 395 host using the
ROCm Docker image (`engramhalo:qwen38-flash-rocm-7.14`, build `68c3a4fc4`).
The benchmark was run after stopping the live server to avoid competing for
unified memory, then the `long` Compose profile was restarted:

```sh
./run-llama-bench.sh --stop-server
```

`llama-bench` loaded the same IQ4_XS three-shard model with `-ngl 999`, lazy
mmap loading, Flash Attention, Q8 K/V cache, 8192 batch / 2048 microbatch, and
4 CPU threads. Each test was repeated three times.

| Test | Average |
|---|---:|
| Prompt processing, 512 tokens | 387.0 tokens/s |
| Prompt processing, 2,048 tokens | 490.4 tokens/s |
| Prompt processing, 8,192 tokens | 483.1 tokens/s |
| Generation, 128 tokens | 22.49 tokens/s |

These are base `llama-bench` prompt-processing and generation measurements;
they do not include the server's MTP / n-gram speculative-decoding path,
vision head, HTTP overhead, or the effect of `--parallel 2`.

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
  step 1 above before any compose command will build.

## Acknowledgements

- [Aristo94/EngramHalo.cpp](https://github.com/Aristo94/EngramHalo.cpp) — the
  Strix Halo patch series and the
  [setup docs](https://github.com/Aristo94/EngramHalo.cpp/tree/strix-halo-qwen4exp/docs/strix-halo)
  this config follows.
- [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
  — model and mmproj.
- [EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF](https://huggingface.co/EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF)
  — prebuilt MTP sidecar.
