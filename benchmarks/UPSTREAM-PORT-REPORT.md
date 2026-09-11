# Upstream port benchmark

## `6788edb4f325c1cb4210997eb79edcab2e27aeaa`

- **Upstream change:** small-M Vulkan matrix optimizations for Qwen.
- **Port method:** manually ported as `drluoto/patches/6788edb.patch`, applied during the image build against drluoto commit `ba5354d46ca63e8225c28e1331f0f7651723ad05`. It includes the operand-swap mat-vec path and small-M split-K change. The fork predates upstream's coopmat tile-selector infrastructure, so that non-applicable selector hunk is intentionally absent.
- **Benchmark status:** not recorded; the image has not been built and run before the execution window expired. No performance conclusion is made.

Intended command after a successful build and healthy server:

```text
uvx llama-benchy --base-url http://127.0.0.1:8080/v1 --model qwen3.8-flash-next-mtp --tokenizer Qwen/Qwen3.8-Flash-Next --pp 2048 --tg 128 --depth 0 --runs 3 --latency-mode generation --no-cache --concurrency 1 --format json
```
