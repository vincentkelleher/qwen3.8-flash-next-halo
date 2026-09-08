# Qwen 3.8 Flash-Next on Strix Halo

![Qwen3.8 Flash Next banner with the Qwen bear and a Framework Desktop](./banner.png)

Docker Compose setup for the Qwen 3.8 Flash-Next MTP service on an AMD Strix
Halo box (Ryzen AI MAX+ 395 / Radeon 8060S). It serves
[`drluoto/Qwen3.8-Flash-Next-MTP-GGUF`](https://huggingface.co/drluoto/Qwen3.8-Flash-Next-MTP-GGUF)
through [drluoto/llama.cpp](https://github.com/drluoto/llama.cpp)
`strix-halo-vulkan` — the only build here that loads that draft head.

![Docker](https://img.shields.io/badge/Docker-compose%20default%20service-2496ED?logo=docker&logoColor=white)
![llama.cpp](https://img.shields.io/badge/llama.cpp-ba5354d46-555)
![Backend](https://img.shields.io/badge/backend-Vulkan%2FRADV-555)

The repo is the deployment config: one `llama-server` service and the download
commands for the weights. The engine is cloned inside the image, so nothing but
the GGUFs needs to sit on disk.

## What is in here

| Path | What it does |
|---|---|
| `docker-compose.yaml` | The default `qwen-drluoto-mtp` service: Vulkan/RADV `llama-server` on port `8080`, API key required |
| `banner.png` | Repo banner |
| `drluoto/Dockerfile` | Image for `drluoto/llama.cpp` `strix-halo-vulkan`, pinned to `ba5354d46` |
| `benchmarks/` | `llama-benchy` report and raw result files for this service |

## Benchmarks

Single-request throughput measured with
[`llama-benchy`](https://github.com/eugr/llama-benchy) against the running
service (2,048-token prompts, 128 tokens generated, uncached prefill). The
service runs with MTP speculative decoding on, so the generation numbers here
are the MTP path, not a draft-off baseline. Decoding stays around 40 t/s at
short context and about 25 t/s at 128K; prompt processing is the weak point and
falls from 573.7 t/s to 231.0 t/s as the context grows.

| Context depth | Prompt processing (t/s) | Generation (t/s) | First response (s) |
|---:|---:|---:|---:|
| 0 | 573.7 ± 4.1 | 40.8 ± 1.9 | 3.70 ± 0.03 |
| 8,192 | 508.0 ± 1.7 | 43.3 ± 2.9 | 20.29 ± 0.07 |
| 32,768 | 408.3 ± 0.4 | 37.7 ± 1.3 | 85.40 ± 0.09 |
| 128,000 | 231.0 ± 0.3 | 25.5 ± 2.0 | 563.18 ± 0.72 |

Values are mean ± std over three runs. `First response` is `ttfr` from
llama-benchy: time until the first stream chunk, prompt processing included.
Full tables (every depth measured, plus two concurrent requests), raw
`llama-benchy` output and the exact command lines:
[`benchmarks/`](benchmarks/).

## Why this branch

The MTP head this service serves is an FR-Spec draft: its output vocabulary is
trimmed to 65,536 frequency-ranked rows with a `d2t` map back to real token
ids. Stock llama.cpp rejects it for the missing `t2d`/`d2t` tensors, and
EngramHalo.cpp does not read that layout either. Upstream puts it plainly: the
draft head "needs this branch; stock llama.cpp will not load it".

## Prerequisites

- AMD Strix Halo (Ryzen AI MAX+ 395 / Radeon 8060S, `gfx1151`), 128 GB unified
  memory. This configuration does not fit in 96 GB.
- ~100 GB free NVMe for the GGUFs. `-lm dio` reads them with `O_DIRECT`, so the
  mount has to be a local filesystem — ext4 on NVMe, not a network share.
- Docker Engine with the Compose plugin, and the `hf` (Hugging Face) CLI.
- The container needs `/dev/dri`: RADV talks to the GPU through the render
  node. `/dev/kfd` is not passed through.

<details>
<summary>Kernel args this box runs with (from the ROCm setup)</summary>

In `/etc/default/grub`, for a 128 GB host:

```text
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

They size the GTT aperture and the TTM page pool. They were tuned for the ROCm
path; the Vulkan path has not been re-measured against other values, but the
90 GiB model plus the driver's own allocations do not fit without them.

</details>

## Setting up

**1. Pull the weights (~98 GB, 91.5 GiB).** They land under `~/Models`, which
`docker-compose.yaml` mounts read-only at `/models`. Keep the layout as
written: the server command line references these exact paths.

```sh
mkdir -p ~/Models && cd ~/Models

# main model, UD-IQ4_XS (3 shards, ~94 GB)
hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  --local-dir unsloth/Qwen3.8-Flash-Next-GGUF \
  --include "*UD-IQ4_XS*"

# replacement chat template — the server exits if this file is missing
hf download froggeric/Qwen-Fixed-Chat-Templates \
  chat_template.jinja \
  --local-dir froggeric/Qwen-Fixed-Chat-Templates

# FR-Spec MTP head (3.64 GB) — the whole reason for this branch
hf download drluoto/Qwen3.8-Flash-Next-MTP-GGUF \
  mtp-Qwen3.8-Flash-Next-Q8_0-frspec-65k.gguf \
  --local-dir drluoto/Qwen3.8-Flash-Next-MTP-GGUF

# vision head (only needed while the --mmproj lines are in the compose file)
hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  mmproj-BF16.gguf \
  --local-dir unsloth/Qwen3.8-Flash-Next-GGUF
```

Expected result:

```text
~/Models
├── drluoto/Qwen3.8-Flash-Next-MTP-GGUF/mtp-Qwen3.8-Flash-Next-Q8_0-frspec-65k.gguf
├── froggeric/Qwen-Fixed-Chat-Templates/chat_template.jinja
└── unsloth/Qwen3.8-Flash-Next-GGUF
    ├── mmproj-BF16.gguf
    └── UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-0000{1,2,3}-of-00003.gguf
```

**2. Create an API key (required).** The service passes `--api-key-file` and
mounts `./.api-key` as a Compose secret, so it will not start without the file,
and every `/v1` request needs it as a bearer token:

```sh
umask 077 && openssl rand -base64 48 > .api-key
```

To serve without auth, comment out the `--api-key-file` lines and the
`secrets:` entry in `docker-compose.yaml`.

## Running

`qwen-drluoto-mtp` is the only service in `docker-compose.yaml` and carries no
`profiles:` key, so it runs on plain `docker compose up` — no `--profile` flag.
The first build clones llama.cpp and compiles it against Vulkan, which takes a
while; later starts reuse the image.

```sh
docker compose up -d --build
docker logs -f qwen38-flash-next-qwen-drluoto-mtp-1
```

Model load means reading ~88 GiB of GGUFs with `O_DIRECT`, so give it a few
minutes. Poll
`/health` until it answers, then check the GPU and the model are the ones you
expect:

```sh
until curl -sf http://127.0.0.1:8080/health >/dev/null; do sleep 10; done
```

```sh
docker compose exec qwen-drluoto-mtp llama-server --list-devices   # takes a minute to init Vulkan
# Vulkan0: Radeon 8060S Graphics (RADV STRIX_HALO) (127488 MiB, ...)

KEY=$(cat .api-key)

curl -s http://127.0.0.1:8080/health
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/v1/models

curl -s -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $KEY" \
  http://127.0.0.1:8080/v1/chat/completions \
  -d '{
    "model": "qwen3.8-flash-next-mtp",
    "messages": [{"role": "user", "content": "Hello"}],
    "temperature": 0
  }'
```

Point an OpenAI-compatible client at `http://<host>:8080/v1` with the model
name `qwen3.8-flash-next-mtp` and the same bearer token. `docker compose down`
stops the service.

The server logs `model loaded` when it is up, and `/health` answers
`200` once the socket is serving.

<details>
<summary>The full server command line</summary>

What `docker-compose.yaml` starts, minus the paths:

| Flag | Value | Why |
|---|---|---|
| `-m` | `UD-IQ4_XS` shard `00001` of `00003` | stock quant; the sidecar was trained against the BF16 base |
| `-md` | `mtp-...-Q8_0-frspec-65k.gguf` | FR-Spec MTP draft head |
| `--spec-type` | `draft-mtp` | MTP speculative decoding |
| `--spec-draft-n-max` | `3` | draft up to 3 tokens per step |
| `--spec-draft-p-min` | `0.0` | no probability floor under a draft |
| `--mmproj` | `mmproj-BF16.gguf` | vision head, not part of the validated configuration |
| `--jinja` + `--chat-template-file` | Froggeric fixed template | replaces the template embedded in the GGUF; `--jinja` has to come first |
| `--reasoning-format` | `deepseek` | thoughts are returned as `message.reasoning_content` |
| `--reasoning-preserve` | — | keep the reasoning trace in the whole history, not just the last assistant message |
| `--temperature` | `1.0` | sampler defaults follow the template's recommendations |
| `--top-k` / `--top-p` / `--min-p` | `20` / `0.95` / `0.0` | pinned explicitly, including where it matches the server default |
| `--presence-penalty` | `0.0` | no penalty for tokens already in the context |
| `-ngl` | `999` | full offload |
| `-fa` | `on` | flash attention |
| `-b` / `-ub` | `2048` / `2048` | batching from the validated host run |
| `-c` | `264000` | shared context |
| `--parallel` | `2` | two slots, ~132,000 tokens each |
| `--ctx-checkpoints` | `8` | lets the parallel slots rotate |
| `-ctk` / `-ctv` | `f16` / `f16` | full-precision K/V; a quantised cache costs acceptance |
| `-lm` | `dio` | model loading mode (`-lm` is `--load-mode`) |
| `--no-webui` | — | API only |
| `--host` / `--port` | `0.0.0.0` / `8080` | in-container bind; see the published port below |
| `--api-key-file` | `/run/secrets/qwen_api_key` | bearer token from `./.api-key` |
| `--alias` | `qwen3.8-flash-next-mtp` | OpenAI model name |

</details>

## Benchmark details

Measured on this box with `llama-benchy` 0.4.0 against the
running service: 2,048-token prompts, 128 tokens generated, three runs per
shape, `--latency-mode generation`, `--no-cache` (uncached prefill every run).
The service runs with `--spec-type draft-mtp`: every number below is with MTP
speculative decoding on, and llama-benchy handles the multi-token chunks that
head produces, counting a burst as the tokens it carries. Values are mean ±
std. `llama-benchy` talks to `/v1/chat/completions`, so this is end-to-end
server throughput, not `llama-bench` internals. "First response"
is `ttfr`: time until the first stream chunk arrives, prompt processing
included.

Concurrency 1 — a single request owns the model:

| Context depth | Prompt processing (t/s) | Generation (t/s) | Peak generation (t/s) | First response (s) |
|---:|---:|---:|---:|---:|
| 0 | 573.7 ± 4.1 | 40.8 ± 1.9 | 41.7 ± 1.9 | 3.70 ± 0.03 |
| 4,096 | 527.3 ± 7.0 | 39.4 ± 3.5 | 39.7 ± 3.7 | 11.79 ± 0.15 |
| 8,192 | 508.0 ± 1.7 | 43.3 ± 2.9 | 43.7 ± 2.6 | 20.29 ± 0.07 |
| 16,384 | 469.3 ± 0.8 | 41.0 ± 2.0 | 41.3 ± 1.7 | 39.41 ± 0.06 |
| 32,768 | 408.3 ± 0.4 | 37.7 ± 1.3 | 38.3 ± 1.3 | 85.40 ± 0.09 |
| 65,536 | 324.7 ± 0.9 | 31.7 ± 1.1 | 32.3 ± 0.9 | 208.25 ± 0.57 |
| 98,304 | 267.3 ± 1.8 | 27.4 ± 1.6 | 27.7 ± 1.7 | 375.58 ± 2.48 |
| 128,000 | 231.0 ± 0.3 | 25.5 ± 2.0 | 26.0 ± 2.2 | 563.18 ± 0.72 |

Concurrency 2 — two simultaneous requests, `--parallel 2`. Throughput is
reported as aggregate across both requests / average per request:

| Context depth | Prompt processing (t/s) | Generation (t/s) | First response (s) |
|---:|---:|---:|---:|
| 0 | 538.5 ± 1.5 / 281.6 ± 3.9 | 43.1 ± 2.5 / 23.7 ± 2.3 | 7.51 ± 0.10 |
| 4,096 | 518.0 ± 0.5 / 292.2 ± 30.6 | 25.8 ± 0.8 / 19.0 ± 5.9 | 21.50 ± 2.23 |
| 8,192 | 502.7 ± 1.4 / 313.8 ± 61.0 | 13.7 ± 0.4 / 15.8 ± 9.0 | 34.15 ± 6.59 |
| 16,384 | 466.6 ± 0.4 / 315.4 ± 81.4 | 6.7 ± 0.1 / 12.8 ± 9.5 | 62.85 ± 16.16 |
| 32,768 | 411.4 ± 0.8 / 290.9 ± 84.9 | 3.1 ± 0.0 / 12.0 ± 10.5 | 131.08 ± 38.18 |

What the numbers say:

- Decoding holds around 40 t/s at short context and falls to ~25 t/s at 128K.
  The server's own log lines report `draft acceptance` around 0.5 on the
  benchmark text (e.g. `0.51667 (62 accepted / 120 generated), mean len = 2.55`).
- Uncached prefill is the hard part on this GPU: a cold 128K prompt takes
  almost ten minutes to process. Keep the prefix cache on (the default) and
  keep sessions warm; these measurements deliberately disable it.
- Two slots share the compute, so interactive concurrency is only comfortable
  at short contexts. Both slots going deep degrades decode badly.
- The 128K depth fits because `--parallel 2` gives each slot ~132,000 tokens.
  At depth 128,000 the prompt plus output leaves little headroom; for full
  native-context work set `--parallel 1`.

Raw runs, the exact `llama-benchy` command lines and the full argument list
are in [`benchmarks/REPORT.md`](benchmarks/REPORT.md).

## Notes and limitations

- The service publishes `0.0.0.0:8080:8080` and binds `--host 0.0.0.0`, so it
  is reachable from every interface the box has. It is behind an API key, but
  change the mapping to `127.0.0.1:8080:8080` if you only serve localhost — and
  do not remove `--api-key-file` while it is published on a LAN address.
- Two settings are load-bearing: `GGML_VK_DISABLE_GDN_CACHE_FUSION=1` sidesteps
  a fused state-cache kernel that corrupts output on the 8060S, and `-lm dio`
  needs `O_DIRECT`. Never add `--no-mmap` alongside it.
- The served chat template is `--chat-template-file` (Froggeric's fixed
  template) with `--reasoning-format deepseek` and `--reasoning-preserve`, not
  the one embedded in the GGUFs. Download it (step 1) or the server exits at
  startup, and keep `--jinja` ahead of it — the server otherwise only accepts
  its built-in templates. `--reasoning-preserve` does nothing unless the
  template advertises `supports_preserve_reasoning`.
- The vision head is along for the ride and unproven on this branch:
  `mmproj-BF16.gguf` is a Qwen3-VL ViT with a `qwen3vl_merger` head, the workloads
  are text-only, and nothing under `tools/mtmd` of `strix-halo-vulkan` mentions
  the `qwen4exp` architecture. If the server dies on `model does not support
  vision input`, delete the two `--mmproj` lines and the service is the plain
  text-only MTP configuration again.
- `--parallel 2` is what this box is validated on; the MTP and sparse-gather
  paths are best validated at low concurrency. For one full-native-context
  session, set `--parallel` to `1`.
- Specs and flags are tuned for one machine (128 GB, NVMe, CPU governor
  `powersave`). Retune before trusting these settings elsewhere.
- Vulkan here is the only path left in `docker-compose.yaml`. The ROCm/HIP
  profiles that used the [EngramHalo.cpp](https://github.com/Aristo94/EngramHalo.cpp)
  engine were removed; upstream reports the Vulkan path as a net loss against a
  stock build on RADV, and this branch has not been compared against ROCm here.
- The fork's own timing tooling is gone: `drluoto/run-bench.sh`, the image's
  `/opt/bench/spektrum.py` replay and the `llama-bench` build target are not in
  the image. The numbers above come from `llama-benchy` against the HTTP API on
  this box — the flags themselves come from the fork and one host pass, so
  measure your own before trusting them elsewhere.
- Server-side sampling defaults are the template's recommended `temperature`
  1.0, `top-k` 20, `top-p` 0.95, `min-p` 0.0 and `presence-penalty` 0.0. Pin
  `temperature: 0` per request for greedy.
- `setup.sh` and `setup.py` (precheck, clone, key, weights, verify) are
  ROCm-era and still name the removed `qwen-long` service and the EasiiX draft
  head. They are out of the working tree and only in git history; follow this
  README for the weights.
- The image pins a fork commit (`ba5354d46`) rather than a release, so the
  branch moving upstream does not change what you build.
- No license file yet.

## Acknowledgements

- [drluoto/llama.cpp](https://github.com/drluoto/llama.cpp) —
  `strix-halo-vulkan`, the MTP head and the state-cache work.
- [drluoto/Qwen3.8-Flash-Next-MTP-GGUF](https://huggingface.co/drluoto/Qwen3.8-Flash-Next-MTP-GGUF)
  — the FR-Spec MTP draft head this service serves.
- [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)
  — model and mmproj.
- [froggeric/Qwen-Fixed-Chat-Templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates)
  — the fixed chat template the server requires, and the recommended sampling
  parameters it pins.
- [Aristo94/EngramHalo.cpp](https://github.com/Aristo94/EngramHalo.cpp) — the
  Strix Halo patch series and the
  [setup docs](https://github.com/Aristo94/EngramHalo.cpp/tree/strix-halo-qwen4exp/docs/strix-halo)
  this config grew out of.
