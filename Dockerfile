# 3DGS Cloud Worker — pre-built container for gsplat + COLMAP/GLOMAP + (optional) SphereSfM
#
# Why this image exists:
#   Wave D experiments (2026-05-27) hit 10+ provisioning failures installing
#   gsplat deps on bare `pytorch/pytorch:*-cuda12.1-cudnn8-devel` instances.
#   Pre-building everything into a GHCR image eliminates the entire class of
#   dep-discovery / pip-install / kernel-compile failures at run-time.
#
# Companion image: ghcr.io/temperaryt/lichtfeld-cloud-worker:* (LichtFeld
# Studio's headless worker). Both share Vast.ai's ssh_direct deployment model;
# this image targets gsplat as the trainer instead.
#
# Base CUDA 12.1.1 / Ubuntu 22.04 (DIVERGES from LichtFeld's 12.8/24.04):
#   gsplat 1.5.3's compile-time CUDA extension build needs the toolkit to match
#   Torch's wheel ABI. Torch 2.1.2 ships +cu121 wheels only; staying on a 12.1
#   CUDA toolkit avoids the toolkit-vs-wheel mismatch that produces silent
#   numerical bugs in fused-ssim / fused-bilagrid. Ubuntu 22.04 + GCC 11 is also
#   the GHA-validated baseline for these git-installed CUDA extensions.
#
# CUDA arch list — same as LichtFeld; covers every card Vast.ai rents to us:
#   75 = RTX 2080/T4   80 = A100   86 = RTX 3090/A4000/A6000
#   89 = RTX 4090/4080 90 = H100

# ─── Stage 1a: COLMAP builder ────────────────────────────────────────────────
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS colmap-builder

ARG MAKE_JOBS=2

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        git cmake ninja-build pkg-config ca-certificates \
        gcc g++ \
        libboost-all-dev \
        libeigen3-dev \
        libflann-dev \
        libfreeimage-dev \
        libmetis-dev \
        libgoogle-glog-dev libgflags-dev \
        libsqlite3-dev \
        libceres-dev \
        libcurl4-openssl-dev \
        libcgal-dev \
        libglew-dev \
        libgl-dev libglu1-mesa-dev libglx-dev libegl-dev mesa-common-dev \
    && rm -rf /var/lib/apt/lists/*

# CUDA stub link so colmap's CUDA bits resolve at build time. Driver-provided
# libcuda.so.1 takes over at runtime via NVIDIA_VISIBLE_DEVICES.
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs

RUN git clone --branch 3.13.0 --depth 1 https://github.com/colmap/colmap /src/colmap \
    && cmake -B /src/colmap/build -S /src/colmap \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/colmap \
        -DCUDA_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86;89;90" \
        -DGUI_ENABLED=OFF \
        -DTESTS_ENABLED=OFF \
        -G Ninja \
    && cmake --build /src/colmap/build -j${MAKE_JOBS} \
    && cmake --install /src/colmap/build \
    && rm -rf /src/colmap


# ─── Stage 1b: GLOMAP builder ────────────────────────────────────────────────
# Installs INTO /opt/colmap (shared prefix). glomap binary lives at
# /opt/colmap/bin/glomap. Matches the LichtFeld pattern.
FROM colmap-builder AS glomap-builder

RUN echo "/opt/colmap/lib" > /etc/ld.so.conf.d/colmap.conf && ldconfig

RUN git clone --recurse-submodules --depth 1 --shallow-submodules \
        https://github.com/colmap/glomap /src/glomap \
    && cmake -B /src/glomap/build -S /src/glomap \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/colmap \
        -DCMAKE_PREFIX_PATH=/opt/colmap \
        -G Ninja \
    && cmake --build /src/glomap/build -j${MAKE_JOBS} \
    && cmake --install /src/glomap/build \
    && rm -rf /src/glomap


# ─── Stage 1c: SphereSfM builder (FAIL-SOFT) ─────────────────────────────────
# Experimental — spherical-camera fork of COLMAP for native equirectangular SfM.
# Build failures here are tolerated: if SphereSfM doesn't compile cleanly
# against CUDA 12.1 / Ubuntu 22.04, the image still ships, just without
# /opt/spheresfm. Runner scripts detect availability at runtime.
#
# Builds into /opt/spheresfm (separate prefix from COLMAP/GLOMAP since binary
# names collide). All build artifacts including failure markers are written
# under /opt/spheresfm so the runtime stage's COPY --from is deterministic.
FROM colmap-builder AS spheresfm-builder

ARG MAKE_JOBS=2

# Try to build. On any failure, leave /opt/spheresfm/BUILD_FAILED marker for
# diagnostics and continue.
RUN mkdir -p /opt/spheresfm && \
    (   set -e; \
        echo "+++ SphereSfM build attempt"; \
        git clone --recurse-submodules --depth 1 \
            https://github.com/json87/SphereSfM /src/spheresfm; \
        cmake -B /src/spheresfm/build -S /src/spheresfm \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/opt/spheresfm \
            -DCUDA_ENABLED=ON \
            -DCMAKE_CUDA_ARCHITECTURES="75;80;86;89;90" \
            -DGUI_ENABLED=OFF \
            -DTESTS_ENABLED=OFF \
            -G Ninja; \
        cmake --build /src/spheresfm/build -j${MAKE_JOBS}; \
        cmake --install /src/spheresfm/build; \
        rm -rf /src/spheresfm; \
        echo "+++ SphereSfM build OK"; \
    ) || ( \
        echo "WARN: SphereSfM build failed — image will ship without it"; \
        rm -rf /src/spheresfm /opt/spheresfm; \
        mkdir -p /opt/spheresfm; \
        echo "build failed during $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /opt/spheresfm/BUILD_FAILED; \
        true \
    )


# ─── Stage 2: Python deps builder ────────────────────────────────────────────
# Compiles gsplat + fused-ssim + fused-bilagrid CUDA extensions ahead of time
# so first-run on Vast is fast (no JIT compile latency).
#
# numpy<2 is enforced in the same install pass via constraints — opencv/scipy
# would otherwise pull numpy 2.x and break Torch 2.1.2's ABI.
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS python-builder

ARG MAKE_JOBS=2
ARG GSPLAT_TAG=v1.5.3

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1
ENV TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6;8.9;9.0"
ENV CMAKE_CUDA_ARCHITECTURES="75;80;86;89;90"

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        git ca-certificates curl \
        python3.10 python3.10-dev python3-pip python3.10-venv \
        ninja-build build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && python3.10 -m pip install --upgrade pip wheel setuptools ninja

# CUDA stub for gsplat / fused-* extension link step.
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs

# Install Torch first (the C++ extensions need its headers + nvcc paths).
RUN python3.10 -m pip install \
        torch==2.1.2+cu121 \
        torchvision==0.16.2+cu121 \
        torchaudio==2.1.2+cu121 \
        --index-url https://download.pytorch.org/whl/cu121

# Install everything else with --no-build-isolation so the PEP 517 build envs
# for fused-ssim / fused-bilagrid can see the parent env's torch. These setup.py
# files `import torch` at module-load (to discover CUDA paths + arch list), and
# pip's default isolated build env doesn't include torch. With this flag, build
# uses the same site-packages we just populated. numpy<2 enforcement in the
# requirements.txt resolver pass still applies.
COPY requirements.txt /tmp/requirements.txt
RUN python3.10 -m pip install --no-build-isolation -r /tmp/requirements.txt

# Bake gsplat's simple_trainer.py from the v1.5.3 tag — no runtime fetch.
RUN mkdir -p /opt/gsplat && \
    curl -fsSL "https://raw.githubusercontent.com/nerfstudio-project/gsplat/${GSPLAT_TAG}/examples/simple_trainer.py" \
        -o /opt/gsplat/simple_trainer.py && \
    curl -fsSL "https://raw.githubusercontent.com/nerfstudio-project/gsplat/${GSPLAT_TAG}/examples/datasets/colmap.py" \
        -o /opt/gsplat/colmap.py && \
    curl -fsSL "https://raw.githubusercontent.com/nerfstudio-project/gsplat/${GSPLAT_TAG}/examples/datasets/normalize.py" \
        -o /opt/gsplat/normalize.py && \
    curl -fsSL "https://raw.githubusercontent.com/nerfstudio-project/gsplat/${GSPLAT_TAG}/examples/datasets/__init__.py" \
        -o /opt/gsplat/datasets__init__.py

# Bake Kotohibi (Metashape 360 → COLMAP cubemap converter) at a pinned ref
# for the equirectangular pipeline. main branch tracked at 2026-05-27.
RUN git clone --depth 1 https://github.com/Kotohibi/Metashape_360_to_COLMAP_plane /opt/kotohibi \
    && rm -rf /opt/kotohibi/.git


# ─── Stage 3: Runtime ────────────────────────────────────────────────────────
# Stays on the devel image (not runtime) because gsplat may invoke nvcc for
# any extension that didn't pre-compile cleanly (e.g. fused-bilagrid). The
# size cost (~1.5 GB) buys us reliability.
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1
ENV TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6;8.9;9.0"

# Minimal runtime deps (COLMAP/GLOMAP linkage + media tools + Python).
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        python3.10 python3.10-dev python3-pip python3.10-venv \
        ca-certificates curl wget git tmux jq \
        ffmpeg imagemagick exiftool p7zip-full unzip \
        libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev \
        libboost-system-dev libboost-test-dev \
        libfreeimage3 libmetis5 libgoogle-glog0v5 libgflags2.2 \
        libsqlite3-0 libceres2 libcurl4 libcgal-dev libglew2.2 \
        libgl1 libglu1-mesa \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/* \
    && python3.10 -m pip install --upgrade pip wheel setuptools

# Pull binaries + libs from each builder.
COPY --from=glomap-builder /opt/colmap /opt/colmap
COPY --from=spheresfm-builder /opt/spheresfm /opt/spheresfm

# Pull Python install (site-packages compiled with target arch list).
COPY --from=python-builder /usr/local/lib/python3.10/dist-packages /usr/local/lib/python3.10/dist-packages
COPY --from=python-builder /usr/local/bin /usr/local/bin
COPY --from=python-builder /opt/gsplat /opt/gsplat
COPY --from=python-builder /opt/kotohibi /opt/kotohibi

# PATH + ldconfig — register COLMAP and SphereSfM shared libs so the loader
# finds them at runtime regardless of CWD.
ENV PATH="/opt/colmap/bin:/opt/spheresfm/bin:${PATH}"
RUN echo "/opt/colmap/lib" > /etc/ld.so.conf.d/3dgs-pipeline.conf \
    && { [ -d /opt/spheresfm/lib ] && echo "/opt/spheresfm/lib" >> /etc/ld.so.conf.d/3dgs-pipeline.conf || true; } \
    && ldconfig \
    && echo "verify colmap:" \
    && (ldd /opt/colmap/bin/colmap | grep "not found" \
        && (echo "BUILD ERROR: colmap unresolved libs"; exit 1) \
        || echo "  colmap: ok") \
    && echo "verify glomap:" \
    && (ldd /opt/colmap/bin/glomap | grep "not found" \
        && (echo "BUILD ERROR: glomap unresolved libs"; exit 1) \
        || echo "  glomap: ok") \
    && echo "verify spheresfm (optional):" \
    && { [ -f /opt/spheresfm/BUILD_FAILED ] \
         && echo "  spheresfm: NOT BUILT (will continue without)" \
         || (ldd /opt/spheresfm/bin/colmap 2>/dev/null | grep "not found" \
             && echo "WARN: spheresfm unresolved libs" \
             || echo "  spheresfm: ok"); }

# Smoke test imports — fail the build NOW if anything is missing.
RUN python3 -c "\
import torch, gsplat, viser, fused_ssim, fused_bilagrid, nerfview;\
import torchmetrics, matplotlib, splines, jaxtyping, rich;\
import cv2, scipy, sklearn;\
import pycolmap;\
from pycolmap import SceneManager;\
print('torch:', torch.__version__, 'cuda_built:', torch.version.cuda);\
print('gsplat:', gsplat.__version__);\
print('all imports OK')"

# Project scripts.
COPY scripts/ /opt/3dgs/scripts/
COPY run/ /opt/3dgs/run/
RUN chmod +x /opt/3dgs/scripts/*.sh /opt/3dgs/run/*.sh

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# No VOLUME — same convention as LichtFeld (direct on Vast ssh_direct mode,
# not docker-run). ENTRYPOINT kept for docker-run smoke testing; Vast overrides.
ENTRYPOINT ["/opt/3dgs/scripts/run_train.sh"]
