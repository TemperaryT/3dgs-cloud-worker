#!/usr/bin/env bash
# Local smoke test — pulls the image, runs a minimal CUDA check, exits.
# Run on WSL (or any host with docker + a recent NVIDIA driver) before
# trusting the image enough to wire into the cloud orchestrator.
#
#   ./smoke_test_direct.sh [v0.1.0]
#
# Verifies:
#   - image pulls
#   - cuda is visible inside the container (--gpus all + driver works)
#   - python imports the full dep set (matches Dockerfile's smoke-test step)
#   - colmap + glomap + ffmpeg launch and print versions
#
# Exit 0 = ok. Non-zero = something is broken; stdout shows what.

set -euo pipefail

TAG="${1:-latest}"
IMAGE="ghcr.io/temperaryt/3dgs-cloud-worker:${TAG}"

echo "+++ smoke test: ${IMAGE}"
docker pull "${IMAGE}" >/dev/null
echo "    pulled."

echo "+++ verify nvidia-smi inside container"
docker run --rm --gpus all "${IMAGE}" nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader

echo "+++ verify python imports"
docker run --rm --gpus all --entrypoint python3 "${IMAGE}" - <<'PYEOF'
import torch, gsplat, viser, fused_ssim, fused_bilagrid, nerfview
import torchmetrics, matplotlib, splines, jaxtyping, rich
import cv2, scipy, sklearn
import pycolmap
from pycolmap import SceneManager
print(f"  torch:  {torch.__version__}  cuda_built: {torch.version.cuda}")
print(f"  cuda available: {torch.cuda.is_available()}  device_count: {torch.cuda.device_count()}")
print(f"  gsplat: {gsplat.__version__}")
print("  all imports OK")
PYEOF

echo "+++ verify binaries"
docker run --rm --entrypoint /bin/bash "${IMAGE}" -c '
    set -e
    colmap --help 2>&1 | head -1
    glomap --help 2>&1 | head -1
    ffmpeg -version 2>&1 | head -1
    exiftool -ver
    ls -la /opt/gsplat/simple_trainer.py
    ls -la /opt/kotohibi/metashape_360_to_colmap.py
    [ -f /opt/spheresfm/BUILD_FAILED ] \
        && echo "  spheresfm: NOT BUILT (image shipped without)" \
        || (ls /opt/spheresfm/bin/ 2>/dev/null | head -3 && echo "  spheresfm: present")
    echo "+++ all binaries OK"
'

echo
echo "✓ smoke test PASSED — ${IMAGE} is ready"
