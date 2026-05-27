#!/usr/bin/env bash
# Container entrypoint — gsplat training on a pre-baked COLMAP bundle.
#
# Mirrors the env-var contract of lichtfeld-cloud-worker's run_train.sh so the
# automation_server orchestrator can reuse most of its plumbing. Differences
# are flagged with GSP_* fallbacks where the semantics diverge.
#
# All verbose output goes to train.log; STATUS.md is what the agent polls.

set -euo pipefail

# ── Env contract (LFS_* names retained for orchestrator compatibility) ────────
GSP_DATA_PATH="${GSP_DATA_PATH:-${LFS_DATA_PATH:-}}"
GSP_OUTPUT_PATH="${GSP_OUTPUT_PATH:-${LFS_OUTPUT_PATH:-/output}}"
GSP_STRATEGY="${GSP_STRATEGY:-${LFS_STRATEGY:-mcmc}}"      # mcmc | default
GSP_ITER="${GSP_ITER:-${LFS_ITER:-30000}}"
GSP_MAX_WIDTH="${GSP_MAX_WIDTH:-${LFS_MAX_WIDTH:-1920}}"
GSP_MAX_CAP="${GSP_MAX_CAP:-${LFS_MAX_CAP:-3000000}}"
GSP_SH_DEGREE="${GSP_SH_DEGREE:-3}"
GSP_TEST_EVERY="${GSP_TEST_EVERY:-8}"
GSP_PROJECT="${GSP_PROJECT:-${LFS_PROJECT:-smoke}}"
GSP_EXTRA_FLAGS="${GSP_EXTRA_FLAGS:-${LFS_EXTRA_FLAGS:-}}"
GSP_EXPERIMENT_ID="${GSP_EXPERIMENT_ID:-${LFS_EXPERIMENT_ID:-}}"
GSP_RUN_ID="${GSP_RUN_ID:-${LFS_RUN_ID:-}}"
GSP_OUTPUT_B2_PREFIX="${GSP_OUTPUT_B2_PREFIX:-${LFS_OUTPUT_B2_PREFIX:-}}"

STATUS_FILE="$GSP_OUTPUT_PATH/STATUS.md"
LOG_FILE="$GSP_OUTPUT_PATH/train.log"
METRICS_REPORT="$GSP_OUTPUT_PATH/metrics_report.txt"
DONE_JSON="$GSP_OUTPUT_PATH/done.json"

write_status() {
    mkdir -p "$(dirname "$STATUS_FILE")"
    printf 'STATE=%s\nNOTE=%s\nUPDATED=%s\n' "$1" "${2:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATUS_FILE"
}

die() { write_status "FAILED" "$1"; echo "FAILED: $1" >&2; exit 1; }
trap 'write_status "FAILED" "line $LINENO"; exit 1' ERR

[[ -z "$GSP_DATA_PATH" ]] && die "GSP_DATA_PATH/LFS_DATA_PATH not set"
[[ -d "$GSP_DATA_PATH" ]] || die "GSP_DATA_PATH not found: $GSP_DATA_PATH"

# ── Sanity gate: bundle must be COLMAP-format with sparse/0/ — gsplat won't
#    accept Nerfstudio transforms.json directly via simple_trainer.py.
if [[ ! -f "$GSP_DATA_PATH/sparse/0/cameras.txt" && ! -f "$GSP_DATA_PATH/sparse/0/cameras.bin" ]]; then
    die "expected COLMAP bundle at $GSP_DATA_PATH/sparse/0/cameras.{txt,bin}"
fi

# ── COLMAP text → binary conversion (gsplat's pycolmap variant requires .bin).
if [[ -f "$GSP_DATA_PATH/sparse/0/cameras.txt" && ! -f "$GSP_DATA_PATH/sparse/0/cameras.bin" ]]; then
    write_status "CONVERTING" "colmap text->binary"
    colmap model_converter \
        --input_path "$GSP_DATA_PATH/sparse/0" \
        --output_path "$GSP_DATA_PATH/sparse/0" \
        --output_type BIN >> "$LOG_FILE" 2>&1 \
        || die "colmap model_converter failed"
fi

# ── Verify PINHOLE camera model (cubemap rewrite invariant) ────────────────
CAMERA_MODEL=$(awk 'NR>3 && NF>4 {print $2; exit}' "$GSP_DATA_PATH/sparse/0/cameras.txt" 2>/dev/null \
               || echo "UNKNOWN")
echo "[INFO] camera_model=$CAMERA_MODEL" >> "$LOG_FILE"
if [[ "$CAMERA_MODEL" != "PINHOLE" && "$CAMERA_MODEL" != "SIMPLE_PINHOLE" \
      && "$CAMERA_MODEL" != "OPENCV" && "$CAMERA_MODEL" != "UNKNOWN" ]]; then
    echo "WARN: unexpected camera_model=$CAMERA_MODEL (gsplat expects pinhole-class)" >> "$LOG_FILE"
fi

# ── Image directory discovery ───────────────────────────────────────────────
if [[ -d "$GSP_DATA_PATH/images" ]]; then
    IMG_DIR="$GSP_DATA_PATH/images"
else
    IMG_DIR="$GSP_DATA_PATH"
fi
frame_count=$(find "$IMG_DIR" -maxdepth 1 -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" \) 2>/dev/null | wc -l)
[[ "$frame_count" -eq 0 ]] && die "no image files found under $IMG_DIR"

mkdir -p "$GSP_OUTPUT_PATH"
write_status "TRAINING" "strategy=$GSP_STRATEGY iter=$GSP_ITER frames=$frame_count max_cap=$GSP_MAX_CAP"

# ── Build gsplat command ────────────────────────────────────────────────────
CMD=(python /opt/gsplat/simple_trainer.py
    "$GSP_STRATEGY"
    --data_dir "$GSP_DATA_PATH"
    --result_dir "$GSP_OUTPUT_PATH"
    --max_steps "$GSP_ITER"
    --sh_degree "$GSP_SH_DEGREE"
    --test_every "$GSP_TEST_EVERY"
    --disable_viewer)

[[ -n "$GSP_MAX_CAP" ]] && CMD+=(--strategy.cap-max "$GSP_MAX_CAP")

# Append free-form flags verbatim (word-split intentionally — caller passes
# e.g. GSP_EXTRA_FLAGS='--use_bilateral_grid --absgrad')
# shellcheck disable=SC2206
if [[ -n "$GSP_EXTRA_FLAGS" ]]; then
    EXTRA_ARR=( $GSP_EXTRA_FLAGS )
    CMD+=( "${EXTRA_ARR[@]}" )
fi

TRAIN_START_TS=$(date -u +%s)
"${CMD[@]}" >> "$LOG_FILE" 2>&1
TRAIN_END_TS=$(date -u +%s)
TRAIN_WALLCLOCK_S=$((TRAIN_END_TS - TRAIN_START_TS))

# ── Find final PLY (gsplat writes ply/point_cloud_*.ply per save_steps) ─────
PLY=$(find "$GSP_OUTPUT_PATH" -name "*.ply" -not -path "*/\.*" | sort -V | tail -1)
[[ -z "$PLY" ]] && die "no PLY artifact found — check $LOG_FILE"

# ── Generate metrics_report.txt (single source of truth for PSNR/SSIM) ──────
# simple_trainer.py writes per-step eval results to stats/. Parse and aggregate.
write_status "REPORTING" "generating metrics_report.txt"
python3 - <<PYEOF >> "$LOG_FILE" 2>&1
import json, glob, os, sys
out = os.environ['GSP_OUTPUT_PATH']
report = os.path.join(out, 'metrics_report.txt')
stats_dir = os.path.join(out, 'stats')
records = []
for path in sorted(glob.glob(os.path.join(stats_dir, '*.json'))):
    try:
        with open(path) as f:
            records.append((os.path.basename(path), json.load(f)))
    except Exception as e:
        print(f"WARN: failed to parse {path}: {e}")
if not records:
    print("WARN: no stats/*.json — metrics_report will be empty")
last_name, last = records[-1] if records else (None, {})
psnr = last.get('psnr', None)
ssim = last.get('ssim', None)
lpips = last.get('lpips', None)
ngauss = last.get('num_GS', last.get('n_gaussians', None))
with open(report, 'w') as f:
    f.write(f"# gsplat metrics report\n")
    f.write(f"# source: {last_name}\n")
    f.write(f"Best PSNR: {psnr}\n")
    f.write(f"Best SSIM: {ssim}\n")
    f.write(f"Best LPIPS: {lpips}\n")
    f.write(f"Final n_gaussians: {ngauss}\n")
print(f"wrote {report}: PSNR={psnr} SSIM={ssim} LPIPS={lpips} nGS={ngauss}")
PYEOF

PLY_SIZE_BYTES=$(stat -c '%s' "$PLY" 2>/dev/null || echo 0)
PLY_SIZE_MB=$((PLY_SIZE_BYTES / 1024 / 1024))
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | tr -d '\r')

# ── B2 upload (env-gated; fail-soft) ─────────────────────────────────────────
UPLOAD_NOTE=""
S3_DEST=""
if [[ -n "${S3_BUCKET:-}" ]]; then
    : "${AWS_ACCESS_KEY_ID:=${S3_ACCESS_KEY_ID:-}}"
    : "${AWS_SECRET_ACCESS_KEY:=${S3_SECRET_ACCESS_KEY:-}}"
    : "${AWS_DEFAULT_REGION:=${AWS_DEFAULT_REGION:-us-east-1}}"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    if [[ -n "$GSP_OUTPUT_B2_PREFIX" ]]; then
        S3_DEST="${GSP_OUTPUT_B2_PREFIX%/}/"
    else
        S3_DEST="s3://$S3_BUCKET/$GSP_PROJECT/$(date -u +%Y%m%dT%H%M%S)/"
    fi
    write_status "UPLOADING" "dest=$S3_DEST"
    aws s3 cp "$GSP_OUTPUT_PATH/" "$S3_DEST" --recursive \
        ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"} \
        >> "$LOG_FILE" 2>&1 \
        && UPLOAD_NOTE=" b2=$S3_DEST" \
        || echo "WARN: B2 upload failed (artifacts still on instance)" >> "$LOG_FILE"
fi

# ── done.json sentinel ──────────────────────────────────────────────────────
cat > "$DONE_JSON" <<DONE_EOF
{
  "schema_version": 1,
  "state": "DONE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "trainer": "gsplat",
  "experiment_id": "$GSP_EXPERIMENT_ID",
  "run_id": "$GSP_RUN_ID",
  "strategy": "$GSP_STRATEGY",
  "max_cap": $GSP_MAX_CAP,
  "iter": $GSP_ITER,
  "sh_degree": $GSP_SH_DEGREE,
  "max_width": $GSP_MAX_WIDTH,
  "extra_flags": "$GSP_EXTRA_FLAGS",
  "ply_filename": "$(basename "$PLY")",
  "ply_size_bytes": $PLY_SIZE_BYTES,
  "ply_size_mb": $PLY_SIZE_MB,
  "wallclock_train_s": $TRAIN_WALLCLOCK_S,
  "gpu_name": "$GPU_NAME",
  "s3_dest": "$S3_DEST",
  "frames_input": $frame_count,
  "camera_model": "$CAMERA_MODEL"
}
DONE_EOF

# Re-upload done.json explicitly (race-safe — bulk cp may have finished before)
if [[ -n "$S3_DEST" ]]; then
    aws s3 cp "$DONE_JSON" "${S3_DEST}done.json" \
        ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"} \
        >> "$LOG_FILE" 2>&1 || \
        echo "WARN: done.json re-upload failed" >> "$LOG_FILE"
fi

write_status "DONE" "ply=$(basename "$PLY")$UPLOAD_NOTE"
