# SuperSplat — Local Self-Hosted Floater Cleanup

Self-hosted instance of [PlayCanvas SuperSplat](https://github.com/playcanvas/supersplat)
for post-hoc 3DGS cleanup. **Runs entirely in the browser (WebGL/WebGPU).
Nothing is uploaded anywhere.**

---

## Why this exists

After training you may have floaters — stray Gaussians that accumulate outside
the subject (especially in difficult backgrounds or masked-then-unmasked areas).
SuperSplat lets you lasso or sphere-select them and delete them before exporting
the cleaned PLY for re-evaluation.

---

## Setup (one-time)

Requires: `git`, `node` + `npm`. If npm is missing, install it first:

```bash
# Recommended (nvm — installs in user space, no sudo):
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install --lts

# Or via apt:
sudo apt update && sudo apt install -y nodejs npm
```

Then:

```bash
bash tools/supersplat/setup.sh
```

This clones the PlayCanvas SuperSplat repo, runs `npm install && npm run build`,
and places the static app in `tools/supersplat/supersplat-src/dist/`.

---

## Start the server

```bash
bash tools/supersplat/serve-local.sh
```

Open: **http://127.0.0.1:8778/**

Override port: `SUPERSPLAT_PORT=9001 bash tools/supersplat/serve-local.sh`

---

## Cleanup workflow

1. Open SuperSplat in your browser.
2. Click **Open** and select your trained PLY from disk. The file is read
   locally by the browser — it is never sent to a server.
3. Use **Sphere Select** (or box select) to highlight floaters.
4. Tip — invert the selection: select the region you want to KEEP
   (your subject), then use **Invert Selection** to select everything outside,
   then **Delete**.
5. Click **Export PLY** to save the cleaned file.
6. Re-run your PSNR comparison (`render_pair.py` + the wipe slider) to verify
   improvement.

---

## IP safety

- Server binds **127.0.0.1 only** — not reachable from LAN or internet.
- SuperSplat is a pure client-side WebGL/WebGPU app: your PLY data never
  leaves the browser's memory.
- Works with the network cable unplugged after initial `npm install`.
- The built `dist/` is entirely static (HTML + JS + CSS). No backend.

---

## Re-running setup

`setup.sh` is idempotent — it will `git pull` if the repo is already cloned
and re-build. Run it again to update SuperSplat to the latest version.
