# Upstream port benchmark

## `28ff0958291ce3465fabd7bd679d4b0edd742bd9`

- **Upstream change:** CPU writes for eligible small Vulkan copies when the context is idle.
- **Port method:** cleanly cherry-picked as `drluoto/patches/28ff095.patch`, applied during the image build against drluoto commit `ba5354d46ca63e8225c28e1331f0f7651723ad05`.
- **Build and health:** passed; the replacement container loaded the model and llama-benchy's coherence check passed.
- **Benchmark:** llama-benchy 0.4.0, c1, uncached, 2,048 PP / 128 TG / depth 0, 3 measured runs, generation-latency mode.

| PP t/s | TG t/s | TTFR (ms) |
|---:|---:|---:|
| 575.42 ± 3.87 | 40.81 ± 1.48 | 3,692.66 ± 23.99 |

Raw output: `results/28ff095-bench.json` and `results/28ff095-bench.log`.
