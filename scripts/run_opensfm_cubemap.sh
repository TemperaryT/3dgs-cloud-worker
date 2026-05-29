#!/usr/bin/env bash
# OpenSfM cubemap training entry point — open-source alternative to the
# Metashape path in run_cubemap_train.sh. De-risks the proprietary Metashape
# dependency (Wave F SfM bake-off).
#
# Unlike the Metashape path, OpenSfM does its OWN spherical→perspective
# conversion via `opensfm undistort` — so Kotohibi is bypassed and
# `opensfm export_colmap` yields a pinhole COLMAP model directly.
#
# Takes:
#   OSF_ERP_DIR  — directory of equirectangular source frames
# Optional:
#   OSF_WORK_DIR — OpenSfM dataset dir (default /workspace/cloud_burst/opensfm_work)
#   OSF_KEEP_PERCENTILE / OSF_BBOX — pre-training sparse crop (see crop_points3d.py)
#
# Env vars for the trainer (GSP_*/LFS_*) pass through to run_train.sh.
#
# NOTE: the exact OpenSfM config for spherical capture (camera_model override,
# undistort subview layout/FoV) is validated during the Wave F run — this is the
# scaffold. If `opensfm` is not present (build was fail-soft), this exits clearly.

set -euo pipefail

command -v opensfm >/dev/null 2>&1 || { echo "FAIL: opensfm CLI not in image (OpenSfM build was fail-soft — check /opt/opensfm/BUILD_FAILED)" >&2; exit 1; }

OSF_ERP_DIR="${OSF_ERP_DIR:-}"
OSF_WORK_DIR="${OSF_WORK_DIR:-/workspace/cloud_burst/opensfm_work}"
OSF_KEEP_PERCENTILE="${OSF_KEEP_PERCENTILE:-}"
OSF_BBOX="${OSF_BBOX:-}"

[[ -z "$OSF_ERP_DIR" || ! -d "$OSF_ERP_DIR" ]] && { echo "FAIL: OSF_ERP_DIR not set or missing" >&2; exit 1; }

# OpenSfM dataset layout: <ds>/images/ + <ds>/config.yaml
mkdir -p "$OSF_WORK_DIR/images"
cp "$OSF_ERP_DIR"/* "$OSF_WORK_DIR/images/" 2>/dev/null || true

# Force the spherical camera model for all frames (GoPro ERP). OpenSfM reads
# camera_models_overrides.json or config; the override file is the robust route.
# NOTE (v0.2.2): the override REPLACES the camera, so it MUST carry width/height —
# otherwise OpenSfM's average_image_size() sees w*h=0 and detect_features dies with
# `ZeroDivisionError: float division by zero`. Read real dims from the first frame.
read OSF_W OSF_H < <(/opt/opensfm/venv/bin/python - "$OSF_WORK_DIR/images" <<'PYEOF'
import sys, glob, os
from PIL import Image
imgs = sorted(glob.glob(os.path.join(sys.argv[1], "*")))
if not imgs:
    print("0 0"); raise SystemExit
im = Image.open(imgs[0]); print(im.width, im.height)
PYEOF
)
[[ "${OSF_W:-0}" -gt 0 && "${OSF_H:-0}" -gt 0 ]] || { echo "FAIL: could not read ERP image dimensions" >&2; exit 1; }
echo "OpenSfM spherical override: ${OSF_W}x${OSF_H}"
cat > "$OSF_WORK_DIR/camera_models_overrides.json" <<JSON
{
  "all": {
    "projection_type": "spherical",
    "width": ${OSF_W},
    "height": ${OSF_H}
  }
}
JSON

# Config: enable colmap export + perspective undistortion of spherical cams.
cat > "$OSF_WORK_DIR/config.yaml" <<'YAML'
processes: 4
# undistort spherical -> perspective subviews (the cube-face equivalent)
undistorted_image_format: jpg
YAML

# Standard OpenSfM pipeline.
opensfm extract_metadata   "$OSF_WORK_DIR"
opensfm detect_features    "$OSF_WORK_DIR"
opensfm match_features     "$OSF_WORK_DIR"
opensfm create_tracks      "$OSF_WORK_DIR"
opensfm reconstruct        "$OSF_WORK_DIR"
opensfm undistort          "$OSF_WORK_DIR"   # spherical -> perspective
opensfm export_colmap      "$OSF_WORK_DIR"

# OpenSfM writes COLMAP text into <ds>/colmap_export/ (or <ds>/; validate during
# Wave F). Normalize into the sparse/0/ layout run_train.sh expects.
SRC_COLMAP=""
for cand in "$OSF_WORK_DIR/colmap_export" "$OSF_WORK_DIR/colmap" "$OSF_WORK_DIR"; do
    if [[ -f "$cand/cameras.txt" || -f "$cand/cameras.bin" ]]; then SRC_COLMAP="$cand"; break; fi
done
[[ -z "$SRC_COLMAP" ]] && { echo "FAIL: could not locate OpenSfM colmap export (cameras.txt)" >&2; exit 1; }

mkdir -p "$OSF_WORK_DIR/train/sparse/0"
cp "$SRC_COLMAP"/cameras.* "$SRC_COLMAP"/images.* "$SRC_COLMAP"/points3D.* "$OSF_WORK_DIR/train/sparse/0/" 2>/dev/null || true
# Undistorted perspective images live under <ds>/undistorted/images/.
if [[ -d "$OSF_WORK_DIR/undistorted/images" ]]; then
    ln -sf "$OSF_WORK_DIR/undistorted/images" "$OSF_WORK_DIR/train/images"
fi

# Optional pre-training sparse crop.
if [[ -n "$OSF_KEEP_PERCENTILE" || -n "$OSF_BBOX" ]]; then
    python /opt/3dgs/scripts/crop_points3d.py \
        --input "$OSF_WORK_DIR/train/sparse/0/points3D.txt" \
        ${OSF_KEEP_PERCENTILE:+--keep-percentile "$OSF_KEEP_PERCENTILE"} \
        ${OSF_BBOX:+--bbox $OSF_BBOX}
fi

export GSP_DATA_PATH="$OSF_WORK_DIR/train"
export LFS_DATA_PATH="$OSF_WORK_DIR/train"
exec /opt/3dgs/scripts/run_train.sh
