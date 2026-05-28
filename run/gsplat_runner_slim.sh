#!/usr/bin/env bash
# gsplat_runner_slim.sh — Vast.ai-side runner for the pre-built 3dgs-cloud-worker
# container. Replaces the 526-line gsplat_runner.sh in automation_server.
#
# The container image (ghcr.io/temperaryt/3dgs-cloud-worker:vX.Y.Z) ships with
# gsplat 1.5.3, COLMAP 3.13.0, GLOMAP, fused-ssim, fused-bilagrid, nerfview,
# pycolmap (rmbrualla), Kotohibi, and simple_trainer.py all pre-installed.
# We no longer apt/pip anything at runtime; the runner just:
#   1. SSHs into the rented instance (Vast launches the image as instance root)
#   2. Downloads the COLMAP bundle from B2
#   3. Sets env vars + invokes /opt/3dgs/scripts/run_train.sh in tmux
#   4. Polls STATUS.md, pulls done.json + PLY back
#
# Called from run_industrial_cage_wave_d.sh (or any future wave launcher).
# Required env vars same as the old runner: BUNDLE_S3, LFS_EXPERIMENT_ID,
# LFS_RUN_ID, LFS_OUTPUT_B2_PREFIX, optionally LFS_MAX_CAP / LFS_ITER /
# LFS_SH_DEGREE / LFS_EXTRA_FLAGS / GPU_DPH for logging.

set -euo pipefail

SSH_HOST="${1:?usage: $0 SSH_HOST SSH_PORT}"
SSH_PORT="${2:-22}"

# Vast.ai ssh_direct instances log in as root. If the caller passed a bare
# host (no user@), prepend root@ so `ssh $SSH_HOST` doesn't fall back to the
# local username and fail with Permission denied (publickey).
[[ "$SSH_HOST" == *@* ]] || SSH_HOST="root@${SSH_HOST}"

for v in BUNDLE_S3 LFS_EXPERIMENT_ID LFS_RUN_ID LFS_OUTPUT_B2_PREFIX; do
    [[ -n "${!v:-}" ]] || { echo "ERROR: $v not set" >&2; exit 2; }
done

# Load S3 creds from automation .env so the SSH'd-in shell has them.
AUTOMATION_ROOT="${AUTOMATION_ROOT:-$HOME/projects/automation_server}"
[[ -f "$AUTOMATION_ROOT/.env" ]] && { set -a; source "$AUTOMATION_ROOT/.env"; set +a; }
AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:?S3_ACCESS_KEY_ID not set}"
AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY not set}"
S3_BUCKET="${S3_BUCKET:-3dgs-pipeline-storage}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"

LFS_MAX_CAP="${LFS_MAX_CAP:-3000000}"
LFS_ITER="${LFS_ITER:-30000}"
LFS_SH_DEGREE="${LFS_SH_DEGREE:-3}"
LFS_EXTRA_FLAGS="${LFS_EXTRA_FLAGS:-}"
GPU_DPH="${GPU_DPH:-0}"

REMOTE_WORK="/workspace/cloud_burst"
REMOTE_BUNDLE_DIR="$REMOTE_WORK/input/${LFS_EXPERIMENT_ID}"
REMOTE_OUTPUT_DIR="$REMOTE_WORK/output/${LFS_EXPERIMENT_ID}"

ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
mkdir -p "$REMOTE_BUNDLE_DIR" "$REMOTE_OUTPUT_DIR"

# Bundle download (image has awscli baked in).
export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'
export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'
${S3_ENDPOINT_URL:+export S3_ENDPOINT_URL='$S3_ENDPOINT_URL'}

echo "+++ downloading bundle $BUNDLE_S3"
aws s3 cp "$BUNDLE_S3" "$REMOTE_BUNDLE_DIR/bundle.tar.gz" \
    \${S3_ENDPOINT_URL:+--endpoint-url "\$S3_ENDPOINT_URL"}

tar -xzf "$REMOTE_BUNDLE_DIR/bundle.tar.gz" -C "$REMOTE_BUNDLE_DIR" --strip-components=0
rm "$REMOTE_BUNDLE_DIR/bundle.tar.gz"

# Sanity-check: PINHOLE gate (per Wave D brief 003).
MODEL=\$(awk 'NR>3 && NF>4 {print \$2; exit}' "$REMOTE_BUNDLE_DIR/sparse/0/cameras.txt" 2>/dev/null || echo UNKNOWN)
echo "[gate] camera_model=\$MODEL"
case "\$MODEL" in
    PINHOLE|SIMPLE_PINHOLE|OPENCV) echo "[gate] ok" ;;
    *) echo "[gate] FAIL: expected PINHOLE-class, got \$MODEL" >&2; exit 3 ;;
esac

# Launch training in tmux. Container scripts live at /opt/3dgs/scripts/.
tmux new-session -d -s train "
    set -a
    GSP_DATA_PATH='$REMOTE_BUNDLE_DIR'
    GSP_OUTPUT_PATH='$REMOTE_OUTPUT_DIR'
    GSP_ITER='$LFS_ITER'
    GSP_MAX_CAP='$LFS_MAX_CAP'
    GSP_SH_DEGREE='$LFS_SH_DEGREE'
    GSP_STRATEGY='mcmc'
    GSP_EXPERIMENT_ID='$LFS_EXPERIMENT_ID'
    GSP_RUN_ID='$LFS_RUN_ID'
    GSP_OUTPUT_B2_PREFIX='$LFS_OUTPUT_B2_PREFIX'
    GSP_EXTRA_FLAGS='$LFS_EXTRA_FLAGS'
    S3_BUCKET='$S3_BUCKET'
    S3_ENDPOINT_URL='${S3_ENDPOINT_URL}'
    AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'
    AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'
    set +a
    bash /opt/3dgs/scripts/run_train.sh
"
echo "+++ training launched in tmux session 'train' (LFS_EXPERIMENT_ID=$LFS_EXPERIMENT_ID)"
REMOTE
