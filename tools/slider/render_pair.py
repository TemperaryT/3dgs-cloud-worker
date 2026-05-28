#!/usr/bin/env python3
"""
render_pair.py — Render two 3DGS PLY files from an identical camera path
to pixel-aligned PNG sequences for the wipe-slider viewer.

Camera path convention:
  poses.json is a dict:
    {
      "intrinsics": {"fx": float, "fy": float, "cx": float, "cy": float},
      "frames": [
        {"world_to_cam": [[4x4 matrix flattened or nested]]},
        ...
      ]
    }
  world_to_cam = a 4x4 matrix that transforms a world-space point into
  camera space (OpenCV convention: +Z into scene, +Y down).

Run inside the 'nerfstudio' conda env, which has gsplat 1.4.0:
    conda run -n nerfstudio python render_pair.py ...
Or activate the env first:
    conda activate nerfstudio && python render_pair.py ...

If CUDA is not available the script will exit with a clear error message.
Pre-rendered frames can still be used with the HTML slider on any machine.
"""

import argparse
import json
import math
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Graceful import guard — lets the file be syntax-checked without a GPU env
# ---------------------------------------------------------------------------

def _require(pkg: str, hint: str = "") -> object:
    """Import or die with a friendly message."""
    import importlib
    try:
        return importlib.import_module(pkg)
    except ModuleNotFoundError:
        msg = f"[render_pair] Missing package '{pkg}'."
        if hint:
            msg += f" {hint}"
        sys.exit(msg)


# ---------------------------------------------------------------------------
# PLY loader — INRIA 3DGS format
# ---------------------------------------------------------------------------

def load_gaussian_ply(ply_path: str):
    """
    Load a 3DGS PLY (INRIA format) into raw numpy arrays.

    Expected per-vertex properties (all float32):
      Positional:   x, y, z
      Opacity:      opacity          (before sigmoid)
      Scale:        scale_0 scale_1 scale_2   (log-scale, before exp)
      Rotation:     rot_0 rot_1 rot_2 rot_3   (quaternion wxyz, before normalise)
      SH DC band:   f_dc_0 f_dc_1 f_dc_2
      SH rest:      f_rest_0 ... f_rest_N     (optional higher-order bands)

    Returns a dict with keys: means, opacities, scales, quats, sh_dc, sh_rest
    All values are numpy float32 arrays.
    """
    plyfile = _require(
        "plyfile",
        "Install with: pip install plyfile  (inside the nerfstudio conda env)",
    )
    np = _require("numpy")

    print(f"[render_pair] Loading {ply_path} …")
    data = plyfile.PlyData.read(ply_path)
    v = data["vertex"]

    props = [p.name for p in v.properties]

    def col(name):
        return v[name].astype("float32")

    means = np.stack([col("x"), col("y"), col("z")], axis=1)          # (N,3)
    opacities = col("opacity")[:, None]                                # (N,1)

    scales = np.stack(
        [col("scale_0"), col("scale_1"), col("scale_2")], axis=1
    )  # (N,3)

    quats = np.stack(
        [col("rot_0"), col("rot_1"), col("rot_2"), col("rot_3")], axis=1
    )  # (N,4)  wxyz

    sh_dc = np.stack([col("f_dc_0"), col("f_dc_1"), col("f_dc_2")], axis=1)  # (N,3)

    rest_cols = sorted([p for p in props if p.startswith("f_rest_")],
                       key=lambda s: int(s.split("_")[-1]))
    if rest_cols:
        sh_rest = np.stack([col(c) for c in rest_cols], axis=1)  # (N, C)
    else:
        sh_rest = None

    n = means.shape[0]
    print(f"[render_pair]   Loaded {n:,} Gaussians  ({len(rest_cols)} SH-rest channels)")
    return dict(means=means, opacities=opacities, scales=scales,
                quats=quats, sh_dc=sh_dc, sh_rest=sh_rest)


# ---------------------------------------------------------------------------
# Orbit camera path generator
# ---------------------------------------------------------------------------

def orbit_poses(centroid, radius, n_frames, height_offset=0.0):
    """
    Generate n_frames evenly-spaced world-to-cam matrices (4x4, float32 numpy)
    orbiting around `centroid` at `radius` in the XZ plane.
    Camera looks toward the centroid; Y is up.

    Returns list of (4,4) numpy arrays.
    """
    np = _require("numpy")
    poses = []
    for i in range(n_frames):
        theta = 2.0 * math.pi * i / n_frames
        # Camera position in world space
        cx = centroid[0] + radius * math.sin(theta)
        cy = centroid[1] + height_offset
        cz = centroid[2] + radius * math.cos(theta)
        cam_pos = np.array([cx, cy, cz], dtype="float32")

        # Look-at
        forward = centroid.astype("float32") - cam_pos
        forward /= np.linalg.norm(forward)
        world_up = np.array([0.0, -1.0, 0.0], dtype="float32")  # OpenCV: Y down
        right = np.cross(forward, world_up)
        norm_r = np.linalg.norm(right)
        if norm_r < 1e-6:
            world_up = np.array([0.0, 0.0, 1.0], dtype="float32")
            right = np.cross(forward, world_up)
            norm_r = np.linalg.norm(right)
        right /= norm_r
        up = np.cross(right, forward)

        # Rotation matrix (rows = right, up, forward in cam convention)
        R = np.stack([right, up, forward], axis=0)  # (3,3)

        w2c = np.eye(4, dtype="float32")
        w2c[:3, :3] = R
        w2c[:3, 3] = -R @ cam_pos
        poses.append(w2c)
    return poses


def ply_bounds(means_np):
    """Return (centroid, radius) from Gaussian means."""
    np = _require("numpy")
    lo = means_np.min(axis=0)
    hi = means_np.max(axis=0)
    centroid = (lo + hi) / 2.0
    radius = float(np.linalg.norm(hi - lo)) * 0.75
    return centroid, radius


# ---------------------------------------------------------------------------
# Camera path loader
# ---------------------------------------------------------------------------

def load_camera_path(path: str):
    """
    Load poses.json.  Returns (intrinsics_dict, list_of_w2c_4x4_numpy).
    """
    np = _require("numpy")
    with open(path) as f:
        data = json.load(f)

    intr = data["intrinsics"]
    frames = []
    for fr in data["frames"]:
        m = fr["world_to_cam"]
        arr = np.array(m, dtype="float32").reshape(4, 4)
        frames.append(arr)
    return intr, frames


# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

def prepare_tensors(gaussians: dict):
    """Convert numpy dict to torch tensors on CUDA (activations applied)."""
    torch = _require("torch")
    np = _require("numpy")

    if not torch.cuda.is_available():
        sys.exit(
            "[render_pair] CUDA not available.  render_pair.py requires a GPU.\n"
            "  If you want to use pre-rendered frames, skip this script and open\n"
            "  index.html in tools/slider/ with frames already in a/ and b/."
        )

    device = torch.device("cuda")

    def t(arr):
        return torch.from_numpy(arr).to(device)

    means = t(gaussians["means"])           # (N,3)
    # Scales: exp() to get actual scale values
    scales = torch.exp(t(gaussians["scales"]))  # (N,3)
    # Quats: normalise  (gsplat expects wxyz, normalised)
    quats = t(gaussians["quats"])
    quats = quats / (quats.norm(dim=-1, keepdim=True) + 1e-9)
    # Opacities: sigmoid
    opacities = torch.sigmoid(t(gaussians["opacities"])).squeeze(-1)  # (N,)

    # Colors from SH DC band only (degree-0 → constant colour).
    # C0 = 0.28209479177387814
    C0 = 0.28209479177387814
    sh_dc = t(gaussians["sh_dc"])           # (N,3)
    colors = sh_dc * C0 + 0.5              # linear sRGB approx, clamp later
    colors = colors.clamp(0.0, 1.0)        # (N,3)

    return means, quats, scales, opacities, colors


def render_frame(means, quats, scales, opacities, colors,
                 w2c_np, intr, width, height):
    """
    Render a single frame using gsplat.rasterization.
    Returns an (H, W, 3) uint8 numpy array.
    """
    torch = _require("torch")
    np = _require("numpy")
    gsplat = _require(
        "gsplat",
        "Activate the 'nerfstudio' conda env which has gsplat 1.4.0 installed.",
    )

    device = means.device

    # viewmats: (1,4,4)
    viewmat = torch.from_numpy(w2c_np).to(device).unsqueeze(0)

    # Ks: (1,3,3)
    K = torch.tensor(
        [[intr["fx"], 0.0, intr["cx"]],
         [0.0, intr["fy"], intr["cy"]],
         [0.0, 0.0, 1.0]],
        dtype=torch.float32, device=device,
    ).unsqueeze(0)

    render_colors, render_alphas, meta = gsplat.rasterization(
        means=means,
        quats=quats,
        scales=scales,
        opacities=opacities,
        colors=colors,
        viewmats=viewmat,
        Ks=K,
        width=width,
        height=height,
        sh_degree=0,       # we already converted SH → RGB above
        near_plane=0.01,
        far_plane=1000.0,
    )
    # render_colors: (1, H, W, 3) float [0,1]
    img = render_colors[0].clamp(0, 1).cpu().numpy()
    img_uint8 = (img * 255).astype("uint8")
    return img_uint8


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(
        description="Render two 3DGS PLYs from an identical camera path."
    )
    p.add_argument("--ply-a", required=True, help="Path to splat A (.ply)")
    p.add_argument("--ply-b", required=True, help="Path to splat B (.ply)")
    p.add_argument(
        "--camera-path",
        default=None,
        help="Path to poses.json (see module docstring for format). "
             "Omit to auto-generate an orbit path.",
    )
    p.add_argument(
        "--orbit",
        type=int,
        default=60,
        metavar="N",
        help="Number of orbit frames when --camera-path is omitted (default: 60).",
    )
    p.add_argument("--out-dir", required=True, help="Output directory.")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument(
        "--label-a", default="A", help="Label for splat A (written to manifest)."
    )
    p.add_argument(
        "--label-b", default="B", help="Label for splat B (written to manifest)."
    )
    return p.parse_args()


def main():
    args = parse_args()

    # Late imports — only needed if we actually render
    np = _require("numpy")
    Image = _require(
        "PIL.Image",
        "Install Pillow: pip install Pillow  (inside nerfstudio env)",
    )
    # Alias for use below
    from PIL import Image as PILImage

    # Load PLYs
    g_a = load_gaussian_ply(args.ply_a)
    g_b = load_gaussian_ply(args.ply_b)

    # Build/load camera path
    if args.camera_path:
        intr, w2c_list = load_camera_path(args.camera_path)
        print(f"[render_pair] Loaded {len(w2c_list)} poses from {args.camera_path}")
    else:
        print(f"[render_pair] Generating {args.orbit}-frame orbit from PLY A bounds …")
        # Use PLY A's bounds to place the orbit
        centroid, radius = ply_bounds(g_a["means"])
        w2c_list = orbit_poses(centroid, radius, args.orbit)
        # Default intrinsics: simple pinhole
        f = max(args.width, args.height) * 1.0
        intr = {
            "fx": f, "fy": f,
            "cx": args.width / 2.0,
            "cy": args.height / 2.0,
        }

    # Prepare output dirs
    out = Path(args.out_dir)
    dir_a = out / "a"
    dir_b = out / "b"
    dir_a.mkdir(parents=True, exist_ok=True)
    dir_b.mkdir(parents=True, exist_ok=True)

    # Prepare GPU tensors — this will exit clearly if no CUDA
    print("[render_pair] Preparing GPU tensors for A …")
    ta = prepare_tensors(g_a)
    print("[render_pair] Preparing GPU tensors for B …")
    tb = prepare_tensors(g_b)

    n = len(w2c_list)
    frames_manifest = []
    for i, w2c in enumerate(w2c_list):
        tag = f"frame_{i:04d}.png"
        print(f"[render_pair] Rendering frame {i+1}/{n} …", end="\r")

        img_a = render_frame(*ta, w2c, intr, args.width, args.height)
        img_b = render_frame(*tb, w2c, intr, args.width, args.height)

        PILImage.fromarray(img_a).save(dir_a / tag)
        PILImage.fromarray(img_b).save(dir_b / tag)
        frames_manifest.append({"frame": i, "a": f"a/{tag}", "b": f"b/{tag}"})

    print()

    manifest = {
        "label_a": args.label_a,
        "label_b": args.label_b,
        "width": args.width,
        "height": args.height,
        "frames": frames_manifest,
    }
    with open(out / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"[render_pair] Done. {n} frame pairs written to {out}/")
    print(f"[render_pair] Serve with: bash tools/slider/serve-local.sh")


if __name__ == "__main__":
    main()
