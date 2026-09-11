# Upstream port benchmark

## `6788edb4f325c1cb4210997eb79edcab2e27aeaa`

- **Upstream change:** small-M Vulkan matrix optimizations for Qwen.
- **Port method:** manually ported as `drluoto/patches/6788edb.patch`, applied during the image build against drluoto commit `ba5354d46ca63e8225c28e1331f0f7651723ad05`. It includes the operand-swap mat-vec path and small-M split-K change. The fork predates upstream's coopmat tile-selector infrastructure, so that non-applicable selector hunk is intentionally absent.
- **Build and health:** passed after correcting the port to restrict the operand swap to the mat-vec helper; the replacement container loaded the model and llama-benchy's coherence check passed.
- **Benchmark:** llama-benchy 0.4.0, c1, uncached, 2,048 PP / 128 TG / depth 0, 3 measured runs, generation-latency mode.

| PP t/s | TG t/s | TTFR (ms) |
|---:|---:|---:|
| 575.65 ± 5.16 | 42.05 ± 1.35 | 3,690.50 ± 31.89 |

Raw output: `results/6788edb-bench.json` and `results/6788edb-bench.log`.
