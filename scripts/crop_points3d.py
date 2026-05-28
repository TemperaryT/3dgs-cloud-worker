#!/usr/bin/env python3
"""Crop a COLMAP sparse points3D model before 3DGS training.

The far-field / sky / floor junk in a sparse reconstruction seeds gaussians in
useless regions ("clouds you fight through to find the render"). Cropping the
sparse points3D BEFORE training stops gaussians initializing there.

Operates on points3D.txt (COLMAP text format) — version-independent, no
dependency on `colmap model_cropper` (which only exists in COLMAP 4.1+; our
container pins 3.13.0). Run this on the bundle's sparse/0/points3D.txt BEFORE
the text->binary model_converter step in run_train.sh.

Two modes:
  --bbox x0 y0 z0 x1 y1 z1     keep points inside this axis-aligned box
  --keep-percentile P          keep points within the P-th percentile of
                               distance from the robust centroid (drops the
                               far-field outlier shell). e.g. 98 drops the
                               furthest 2%.

Either mode can be combined; bbox is applied first, then percentile.
"""
import argparse
import sys
from pathlib import Path


def read_points3d_txt(path):
    """Yield (raw_line, x, y, z) for each data line; preserve header lines."""
    header = []
    rows = []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                header.append(line)
                continue
            if not line.strip():
                continue
            parts = line.split()
            # POINT3D_ID X Y Z R G B ERROR TRACK[]...
            x, y, z = float(parts[1]), float(parts[2]), float(parts[3])
            rows.append((line, x, y, z))
    return header, rows


def robust_centroid(rows):
    xs = sorted(r[1] for r in rows)
    ys = sorted(r[2] for r in rows)
    zs = sorted(r[3] for r in rows)
    mid = len(rows) // 2
    return xs[mid], ys[mid], zs[mid]  # component-wise median


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, help="path to points3D.txt")
    ap.add_argument("--output", help="output path (default: overwrite input)")
    ap.add_argument("--bbox", nargs=6, type=float, metavar=("X0", "Y0", "Z0", "X1", "Y1", "Z1"),
                    help="keep points inside this AABB")
    ap.add_argument("--keep-percentile", type=float, metavar="P",
                    help="keep points within P-th percentile of distance from median centroid")
    args = ap.parse_args()

    inp = Path(args.input)
    if not inp.is_file():
        sys.exit(f"not found: {inp}")
    out = Path(args.output) if args.output else inp

    header, rows = read_points3d_txt(inp)
    n0 = len(rows)
    if n0 == 0:
        sys.exit("no points found")

    if args.bbox:
        x0, y0, z0, x1, y1, z1 = args.bbox
        lo = (min(x0, x1), min(y0, y1), min(z0, z1))
        hi = (max(x0, x1), max(y0, y1), max(z0, z1))
        rows = [r for r in rows
                if lo[0] <= r[1] <= hi[0] and lo[1] <= r[2] <= hi[1] and lo[2] <= r[3] <= hi[2]]

    if args.keep_percentile is not None:
        if not 0 < args.keep_percentile <= 100:
            sys.exit("--keep-percentile must be in (0, 100]")
        cx, cy, cz = robust_centroid(rows)
        dist = [((r[1] - cx) ** 2 + (r[2] - cy) ** 2 + (r[3] - cz) ** 2, r) for r in rows]
        dist.sort(key=lambda t: t[0])
        keep_n = max(1, int(len(dist) * args.keep_percentile / 100.0))
        rows = [t[1] for t in dist[:keep_n]]

    if not args.bbox and args.keep_percentile is None:
        sys.exit("specify --bbox and/or --keep-percentile")

    with open(out, "w") as f:
        if header:
            f.writelines(header)
        else:
            f.write("# 3D point list with one line of data per point:\n")
            f.write("#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n")
        f.write(f"# Number of points: {len(rows)}, mean track length: 0\n")
        for raw, *_ in rows:
            f.write(raw)

    print(f"crop_points3d: {n0} -> {len(rows)} points ({100*len(rows)/n0:.1f}% kept) -> {out}")


if __name__ == "__main__":
    main()
