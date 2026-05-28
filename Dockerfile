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
        git ninja-build pkg-config ca-certificates \
        gcc g++ \
        python3 python3-pip \
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
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir -q "cmake>=3.30,<4"

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
        # v0.1.x failed here: src/feature/sift.cc uses legacy GL constants
        # (GL_LUMINANCE, GL_UNSIGNED_BYTE) that modern Mesa headers don't pull
        # into that TU, and -DGUI_ENABLED=OFF doesn't gate them. Inject guarded
        # defines at the top of the file so the constants resolve without
        # depending on GL header include order.
        sed -i '1i #ifndef GL_LUMINANCE\n#define GL_LUMINANCE 0x1909\n#endif\n#ifndef GL_UNSIGNED_BYTE\n#define GL_UNSIGNED_BYTE 0x1401\n#endif' \
            /src/spheresfm/src/feature/sift.cc; \
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


# ─── Stage 1d: OpenSfM builder (FAIL-SOFT) ───────────────────────────────────
# Open-source spherical SfM — primary candidate to replace Metashape. Native
# `opensfm export_colmap` outputs cameras.txt/images.txt/points3D.txt, exactly
# what Kotohibi + gsplat consume. Built into an isolated venv at
# /opt/opensfm/venv so its Python deps (opencv/numpy/scipy) can't collide with
# the training env's pinned numpy<2 / torch stack. Fail-soft: if it won't
# build, the image still ships (SphereSfM or Metashape carry the SfM step).
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS opensfm-builder

ARG MAKE_JOBS=2
ENV DEBIAN_FRONTEND=noninteractive

RUN mkdir -p /opt/opensfm && \
    (   set -e; \
        echo "+++ OpenSfM build attempt"; \
        apt-get update -qq && apt-get install -y -qq --no-install-recommends \
            git cmake build-essential ca-certificates \
            libeigen3-dev libopencv-dev libceres-dev libsuitesparse-dev \
            libgoogle-glog-dev libgflags-dev \
            python3 python3-dev python3-pip python3-venv; \
        git clone --recursive --depth 1 \
            https://github.com/mapillary/OpenSfM /opt/opensfm/src; \
        python3 -m venv /opt/opensfm/venv; \
        /opt/opensfm/venv/bin/pip install --no-cache-dir --upgrade pip wheel setuptools; \
        /opt/opensfm/venv/bin/pip install --no-cache-dir "numpy<2" ; \
        # Modern OpenSfM is pyproject.toml-driven: `pip install -e .` runs the
        # cmake C++ build AND wires the pybind extensions (pybundle, pygeometry,
        # ...) into the importable package. v0.2.0 used `setup.py build` which
        # compiled into cmake_build/ but never made them importable (pybundle
        # ImportError). Matches OpenSfM's official Dockerfile.ubuntu24.
        cd /opt/opensfm/src && \
            /opt/opensfm/venv/bin/pip install --no-cache-dir -e . ; \
        # Verify the extension actually imports — turn a silent miss into a
        # build failure so the fail-soft marker fires instead of shipping broken.
        /opt/opensfm/venv/bin/python -c "from opensfm import pybundle, pygeometry; print('opensfm extensions import OK')"; \
        rm -rf /var/lib/apt/lists/*; \
        echo "+++ OpenSfM build OK"; \
    ) || ( \
        echo "WARN: OpenSfM build failed — image will ship without it"; \
        rm -rf /opt/opensfm; \
        mkdir -p /opt/opensfm; \
        echo "build failed during $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /opt/opensfm/BUILD_FAILED; \
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

# Bake gsplat's examples/ tree from the v1.5.3 tag — no runtime fetch.
# Clone the whole repo shallowly, copy examples/, drop the rest. simple_trainer.py
# imports from `datasets.colmap`, `datasets.traj`, `utils`, `lib_bilagrid` —
# need the full tree, not just the entry point.
RUN git clone --depth 1 --branch "${GSPLAT_TAG}" \
        https://github.com/nerfstudio-project/gsplat /tmp/gsplat-src \
    && mkdir -p /opt/gsplat \
    && cp -r /tmp/gsplat-src/examples/. /opt/gsplat/ \
    && rm -rf /tmp/gsplat-src

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
        libopencv-dev libsuitesparse-dev \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/* \
    && python3.10 -m pip install --upgrade pip wheel setuptools

# Pull binaries + libs from each builder.
COPY --from=glomap-builder /opt/colmap /opt/colmap
COPY --from=spheresfm-builder /opt/spheresfm /opt/spheresfm
COPY --from=opensfm-builder /opt/opensfm /opt/opensfm

# Pull Python install (site-packages compiled with target arch list).
COPY --from=python-builder /usr/local/lib/python3.10/dist-packages /usr/local/lib/python3.10/dist-packages
COPY --from=python-builder /usr/local/bin /usr/local/bin
COPY --from=python-builder /opt/gsplat /opt/gsplat
COPY --from=python-builder /opt/kotohibi /opt/kotohibi

# OpenSfM CLI wrapper — runs from its source tree with its isolated venv on
# PATH (so bin/opensfm picks up the venv python3, not the training python).
RUN if [ ! -f /opt/opensfm/BUILD_FAILED ]; then \
        printf '#!/bin/bash\nexport PATH="/opt/opensfm/venv/bin:$PATH"\ncd /opt/opensfm/src && exec ./bin/opensfm "$@"\n' \
            > /usr/local/bin/opensfm && chmod +x /usr/local/bin/opensfm; \
    fi

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
             || echo "  spheresfm: ok"); } \
    && echo "verify opensfm (optional):" \
    && { [ -f /opt/opensfm/BUILD_FAILED ] \
         && echo "  opensfm: NOT BUILT (will continue without)" \
         || echo "  opensfm: present at /opt/opensfm"; }

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

# Pre-bake LPIPS AlexNet weights (~233 MB) so training is offline-capable and
# doesn't stall at first eval downloading them. simple_trainer.py instantiates
# LearnedPerceptualImagePatchSimilarity(net_type='alex'). Fail-soft — if the
# download flakes during build, training falls back to runtime download.
RUN python3 -c "\
from torchmetrics.image.lpip import LearnedPerceptualImagePatchSimilarity as L;\
L(net_type='alex');\
print('LPIPS alex weights cached')" \
    || echo "WARN: LPIPS prebake failed (will download at runtime)"

# Project scripts.
COPY scripts/ /opt/3dgs/scripts/
COPY run/ /opt/3dgs/run/
RUN chmod +x /opt/3dgs/scripts/*.sh /opt/3dgs/run/*.sh

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# No VOLUME — same convention as LichtFeld (direct on Vast ssh_direct mode,
# not docker-run). ENTRYPOINT kept for docker-run smoke testing; Vast overrides.
ENTRYPOINT ["/opt/3dgs/scripts/run_train.sh"]
