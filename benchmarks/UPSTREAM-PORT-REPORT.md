# Upstream port benchmark

## `28ff0958291ce3465fabd7bd679d4b0edd742bd9`

- **Upstream change:** CPU writes for eligible small Vulkan copies when the context is idle.
- **Port method:** cleanly cherry-picked as `drluoto/patches/28ff095.patch`, applied during the image build against drluoto commit `ba5354d46ca63e8225c28e1331f0f7651723ad05`.
- **Benchmark status:** not recorded. The replacement image build did not complete before the execution window expired (Ubuntu package mirror stalled); do not treat the IQ4_XS branch's measurements as results for this branch.

Intended command after a successful build and healthy server:

```text
uvx llama-benchy --base-url http://127.0.0.1:8080/v1 --model qwen3.8-flash-next-mtp --tokenizer Qwen/Qwen3.8-Flash-Next --pp 2048 --tg 128 --depth 0 --runs 3 --latency-mode generation --no-cache --concurrency 1 --format json
```
