# 3dgs-cloud-worker

Pre-built container for cloud GPU 3D Gaussian Splatting runs using
[**gsplat**](https://github.com/nerfstudio-project/gsplat) as the trainer.
Companion to [`lichtfeld-cloud-worker`](https://github.com/TemperaryT/lichtfeld-cloud-worker)
in the same pipeline — both deploy via Vast.ai `ssh_direct`, run via the
`automation_server` orchestrator, write COLMAP/PSNR/PLY artifacts to B2.

**Image:** `ghcr.io/temperaryt/3dgs-cloud-worker:<tag>` (public after first
publish).

## Why this exists

Wave D experiments on 2026-05-27 hit 10+ provisioning failures installing
gsplat dependencies on bare `pytorch/pytorch:*-cuda12.1-cudnn8-devel` Vast
instances: missing pip packages, transitive numpy<2 conflicts, CUDA-extension
compile failures, simple_trainer.py runtime fetch network drops. Baking
everything into a GHCR image eliminates the entire class of failure.

## Contents

| Component | Version / Pin | Path inside image |
|---|---|---|
| Base | `nvidia/cuda:12.1.1-devel-ubuntu22.04` | — |
| Python | 3.10 | `/usr/bin/python3.10` |
| Torch | 2.1.2+cu121 | site-packages |
| gsplat | 1.5.3 | site-packages |
| nerfview | commit `4538024` | site-packages |
| fused-ssim | commit `328dc98` | site-packages |
| fused-bilagrid | commit `90f9788` | site-packages |
| pycolmap (rmbrualla) | commit `cc7ea4b` | site-packages |
| COLMAP | 3.13.0 (CUDA-built) | `/opt/colmap/bin/colmap` |
| GLOMAP | latest (CUDA-built) | `/opt/colmap/bin/glomap` |
| SphereSfM | latest (FAIL-SOFT — may be absent) | `/opt/spheresfm/bin/` |
| gsplat `simple_trainer.py` | gsplat tag v1.5.3 | `/opt/gsplat/simple_trainer.py` |
| Kotohibi 360→COLMAP | latest | `/opt/kotohibi/metashape_360_to_colmap.py` |
| ffmpeg, imagemagick, exiftool, jq, awscli | apt + pip latest | `$PATH` |

CUDA architectures compiled: `75;80;86;89;90` (RTX 2080/T4 → A100 → 3090/A4000/A6000 → 4090/4080 → H100). Vast.ai rents nothing below 75 anymore.

## Entrypoint contract (`/opt/3dgs/scripts/run_train.sh`)

Env vars (LFS_* aliases retained for orchestrator compatibility with
lichtfeld-cloud-worker; GSP_* takes precedence when both are set):

| Var | Default | Purpose |
|---|---|---|
| `GSP_DATA_PATH` / `LFS_DATA_PATH` | — | COLMAP bundle root (expects `sparse/0/` + `images/`) |
| `GSP_OUTPUT_PATH` / `LFS_OUTPUT_PATH` | `/output` | Where train.log, STATUS.md, splat.ply, done.json land |
| `GSP_STRATEGY` / `LFS_STRATEGY` | `mcmc` | gsplat strategy (mcmc / default) |
| `GSP_ITER` / `LFS_ITER` | `30000` | training steps |
| `GSP_MAX_CAP` / `LFS_MAX_CAP` | `3000000` | hard Gaussian cap |
| `GSP_SH_DEGREE` | `3` | spherical-harmonic degree |
| `GSP_TEST_EVERY` | `8` | eval-frame stride (`--test_every`) |
| `GSP_EXTRA_FLAGS` / `LFS_EXTRA_FLAGS` | — | passthrough word-split to simple_trainer.py |
| `GSP_EXPERIMENT_ID` / `LFS_EXPERIMENT_ID` | — | tag emitted in done.json |
| `GSP_OUTPUT_B2_PREFIX` / `LFS_OUTPUT_B2_PREFIX` | — | overrides default S3 dest |
| `S3_BUCKET` / `S3_ENDPOINT_URL` / `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | — | B2 upload creds (translated to AWS_*) |

Writes `STATUS.md` at each state transition (`TRAINING` → `REPORTING` →
`UPLOADING` → `DONE` | `FAILED`). The orchestrator polls this for liveness.

## Cubemap pipeline (`/opt/3dgs/scripts/run_cubemap_train.sh`)

For raw 360 equirectangular workflows. Bakes ERP → 6-face pinhole COLMAP via
Kotohibi, then chains into `run_train.sh`. Inputs:

| Var | Required | Purpose |
|---|---|---|
| `CUBE_ERP_DIR` | yes | directory of equirectangular source frames |
| `CUBE_XML` | yes | Metashape Agisoft Spherical XML camera export |
| `CUBE_PLY` | no | Metashape sparse point cloud (passed to Kotohibi via `--ply`) |
| `CUBE_CROP_SIZE` | no | face crop pixel size (default 1024) |
| `CUBE_FOV_DEG` | no | face FoV (default 90) |
| `CUBE_NUM_WORKERS` | no | reprojection worker count (default 4) |

## Local smoke test

```bash
./run/smoke_test_direct.sh v0.1.0
```

Pulls the image, runs `nvidia-smi` inside the container, imports the full
Python dep set, verifies COLMAP/GLOMAP/ffmpeg/exiftool binaries, confirms
baked `simple_trainer.py` and Kotohibi presence. Requires a host with
NVIDIA driver + `docker --gpus all` working.

## Build via GHA

```bash
gh workflow run build-and-push.yml -f tag=v0.1.0 -f gsplat_tag=v1.5.3
gh run watch
```

First (cold) build ~90–120 min on `ubuntu-latest`. Cached re-runs ~20–30 min
via `type=gha`.

After the first push, make the package public **once**:

```bash
gh api -X PATCH /user/packages/container/3dgs-cloud-worker/visibility \
    -f visibility=public
```

## License

MIT — see `LICENSE`.
