# Upstream port benchmark

## `df750f76bb6126566621803b69ddaeb993be5b08`

- **Upstream change:** dedicated IQ4_XS Vulkan mat-vec shader.
- **Port method:** applied as `drluoto/patches/df750f7.patch` during the image build against drluoto commit `ba5354d46ca63e8225c28e1331f0f7651723ad05`. The shader-generator conflict was resolved while preserving the fork's existing type routing.
- **Build:** passed; the build log includes generation of `mul_mat_vec_iq4_xs.comp`.
- **Benchmark:** llama-benchy 0.4.0, c1, uncached, 2,048 PP / 128 TG / depth 0, 3 measured runs, generation-latency mode.

| PP t/s | TG t/s | TTFR (ms) |
|---:|---:|---:|
| 578.16 ± 10.83 | 40.95 ± 4.41 | 3,674.36 ± 67.11 |

Raw output: `results/df750f7-bench.json` and `results/df750f7-bench.log`.
