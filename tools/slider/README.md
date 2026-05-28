# 3DGS Wipe Slider

Compare two trained Gaussian-splat PLYs side-by-side with a draggable wipe divider.
**All processing is local. Nothing is uploaded anywhere.**

---

## Quick start

### 1. Render matching frame sequences

Activate the `nerfstudio` conda env (which has gsplat 1.4.0):

```bash
conda activate nerfstudio
python tools/slider/render_pair.py \
  --ply-a experiments/lichtfeld_run/point_cloud.ply \
  --ply-b experiments/gsplat_run/point_cloud.ply \
  --out-dir /tmp/slider_frames \
  --label-a "LichtFeld" \
  --label-b "gsplat" \
  --width 1280 --height 720
```

This writes:
- `/tmp/slider_frames/a/frame_0000.png … frame_NNNN.png`
- `/tmp/slider_frames/b/frame_0000.png … frame_NNNN.png`
- `/tmp/slider_frames/manifest.json`

**Providing a camera path (recommended for meaningful comparison):**

```bash
python tools/slider/render_pair.py \
  --ply-a A.ply --ply-b B.ply \
  --camera-path my_poses.json \
  --out-dir /tmp/slider_frames
```

`poses.json` format:
```json
{
  "intrinsics": { "fx": 1000, "fy": 1000, "cx": 640, "cy": 360 },
  "frames": [
    { "world_to_cam": [[1,0,0,0],[0,1,0,0],[0,0,1,3],[0,0,0,1]] },
    ...
  ]
}
```
`world_to_cam` is a 4×4 matrix (OpenCV convention: +Z into scene, +Y down).

If `--camera-path` is omitted, an orbit of `--orbit N` (default 60) poses is
auto-generated from the bounding box of PLY A.

**No GPU / CUDA not available?**
The render step requires CUDA. If you have pre-rendered PNGs from another machine,
skip to step 2 — copy the `a/`, `b/`, and `manifest.json` into `tools/slider/`
and serve as below.

---

### 2. Copy frames into the slider directory

```bash
cp -r /tmp/slider_frames/{a,b,manifest.json} tools/slider/
```

Or use `--out-dir tools/slider/` when running render_pair.py.

---

### 3. Serve locally

```bash
bash tools/slider/serve-local.sh
```

Open: **http://127.0.0.1:8777/index.html**

Override port: `SLIDER_PORT=9000 bash tools/slider/serve-local.sh`

---

## IP safety

- Server binds **127.0.0.1 only** — not reachable from LAN or internet.
- No CDN, no analytics, no external requests — pure vanilla JS.
- Works with the network cable unplugged.
- Nothing in this tool uploads or transmits PLY data.

---

## Controls

| Action | Control |
|---|---|
| Drag wipe divider | Click and drag the centre line |
| Move divider | Click anywhere on the image |
| Step frames | Arrow keys ← → |
| Jump to frame | Frame scrubber at the bottom |

Labels can be set in manifest.json (via `--label-a` / `--label-b`) or overridden
in the URL: `?label_a=LichtFeld&label_b=gsplat`
