# syntax=docker/dockerfile:1.7
#
# llama.cpp for the Qwen 3.8 Flash-Next MTP service: the
# [drluoto/llama.cpp](https://github.com/drluoto/llama.cpp) `strix-halo-vulkan`
# branch, built against Vulkan/RADV.
#
# This is the only build on Strix Halo that runs the FR-Spec MTP sidecar
# (`--spec-type draft-mtp` with a `qwen4exp` MTP head) on Vulkan. The tree is
# pinned to the commit this configuration was validated on.
#
# Build:
#   docker build -t drluoto-llamacpp:strix-halo-vulkan drluoto/
#
# The image is the build context of the default Compose service
# (`qwen-drluoto-mtp`).

ARG UBUNTU_VERSION=26.04

FROM ubuntu:${UBUNTU_VERSION} AS builder
ARG DEBIAN_FRONTEND=noninteractive
ARG LLAMA_REPO=https://github.com/drluoto/llama.cpp.git
ARG LLAMA_BRANCH=strix-halo-vulkan
ARG LLAMA_REF=ba5354d46ca63e8225c28e1331f0f7651723ad05
ARG LLAMA_UPSTREAM_PATCH=28ff095.patch

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl git ninja-build pkg-config \
        glslc libvulkan-dev spirv-headers vulkan-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# Ported upstream Vulkan change, kept as a patch because this fork carries
# Strix Halo-specific work that prevents a clean upstream cherry-pick.
COPY patches/ /build/patches/
# The pinned commit lives on its own branch, so the clone has to fetch that
# branch: a default-branch clone does not carry the commit at all.
RUN git clone --single-branch --branch "${LLAMA_BRANCH}" "${LLAMA_REPO}" llama.cpp \
    && cd llama.cpp \
    && git checkout "${LLAMA_REF}" \
    && git --no-pager log -1 --oneline \
    && git apply --check "/build/patches/${LLAMA_UPSTREAM_PATCH}" \
    && git apply "/build/patches/${LLAMA_UPSTREAM_PATCH}"

WORKDIR /build/llama.cpp
RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_VULKAN=ON \
        -DGGML_NATIVE=ON \
        -DLLAMA_CURL=OFF \
    && cmake --build build \
        --target llama-server \
        --parallel "$(nproc)"

FROM ubuntu:${UBUNTU_VERSION} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libgomp1 libvulkan1 mesa-vulkan-drivers \
        python3-minimal vulkan-tools \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/llama.cpp/build/bin/llama-server /usr/local/bin/
COPY --from=builder /build/llama.cpp/build/bin/*.so*        /usr/local/lib/
RUN ldconfig

WORKDIR /models
ENV AMD_VULKAN_ICD=RADV
# Required by this branch: the fused GDN state-cache path corrupts output here.
ENV GGML_VK_DISABLE_GDN_CACHE_FUSION=1
ENV VK_LOADER_DEBUG=error

EXPOSE 8080
# No ENTRYPOINT: the Compose service spells out the full command line, starting
# with llama-server itself, so an entrypoint would end up as the first argument.
CMD ["llama-server", "--help"]
