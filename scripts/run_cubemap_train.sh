#!/usr/bin/env bash
# Cubemap training entry point — 360 equirectangular pipeline.
#
# Takes:
#   CUBE_ERP_DIR  — directory of equirectangular source frames
#   CUBE_XML      — Metashape Agisoft Spherical XML camera export
#   CUBE_PLY      — Metashape sparse point cloud (optional but recommended)
#
# Pipeline:
#   1. Run Kotohibi (Metashape_360_to_COLMAP_plane) → produces 6 pinhole
#      cube faces per ERP frame + COLMAP cameras.txt/images.txt/points3D.txt
#   2. Move into the layout run_train.sh expects (sparse/0/, images/)
#   3. Delegate to run_train.sh for training, metrics, upload
#
# Env vars passed through to run_train.sh (GSP_* / LFS_*) all still apply.

set -euo pipefail

CUBE_ERP_DIR="${CUBE_ERP_DIR:-}"
CUBE_XML="${CUBE_XML:-}"
CUBE_PLY="${CUBE_PLY:-}"
CUBE_CROP_SIZE="${CUBE_CROP_SIZE:-1024}"
CUBE_FOV_DEG="${CUBE_FOV_DEG:-90}"
CUBE_NUM_WORKERS="${CUBE_NUM_WORKERS:-4}"
CUBE_WORK_DIR="${CUBE_WORK_DIR:-/workspace/cloud_burst/cubemap_work}"

[[ -z "$CUBE_ERP_DIR" || ! -d "$CUBE_ERP_DIR" ]] && { echo "FAIL: CUBE_ERP_DIR not set or missing" >&2; exit 1; }
[[ -z "$CUBE_XML" || ! -f "$CUBE_XML" ]] && { echo "FAIL: CUBE_XML not set or missing" >&2; exit 1; }

mkdir -p "$CUBE_WORK_DIR"

# Kotohibi rewrite — produces images/, cameras.txt, images.txt, points3D.txt
# in the work dir.
python /opt/kotohibi/metashape_360_to_colmap.py \
    --images "$CUBE_ERP_DIR" \
    --xml "$CUBE_XML" \
    --output "$CUBE_WORK_DIR" \
    ${CUBE_PLY:+--ply "$CUBE_PLY"} \
    --crop-size "$CUBE_CROP_SIZE" \
    --fov-deg "$CUBE_FOV_DEG" \
    --num-workers "$CUBE_NUM_WORKERS" \
    --no-rotate-z180

# Restructure into COLMAP-standard layout (sparse/0/).
mkdir -p "$CUBE_WORK_DIR/sparse/0"
mv "$CUBE_WORK_DIR"/{cameras,images,points3D}.txt "$CUBE_WORK_DIR/sparse/0/" 2>/dev/null || true
mv "$CUBE_WORK_DIR"/points3D.ply "$CUBE_WORK_DIR/sparse/0/" 2>/dev/null || true

# Hand off to the trainer.
export GSP_DATA_PATH="$CUBE_WORK_DIR"
export LFS_DATA_PATH="$CUBE_WORK_DIR"  # backwards-compat
exec /opt/3dgs/scripts/run_train.sh
