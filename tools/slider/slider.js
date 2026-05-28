/**
 * slider.js — Pure-vanilla wipe slider for 3DGS frame comparison.
 * No external dependencies. Works fully offline.
 *
 * Reads manifest.json from the same directory.
 * manifest.json schema:
 *   {
 *     "label_a": "LichtFeld",
 *     "label_b": "gsplat",
 *     "width": 1280,
 *     "height": 720,
 *     "frames": [
 *       { "frame": 0, "a": "a/frame_0000.png", "b": "b/frame_0000.png" },
 *       ...
 *     ]
 *   }
 *
 * Labels can also be overridden via URL query params:
 *   ?label_a=LichtFeld&label_b=gsplat
 */

(function () {
  "use strict";

  // -------------------------------------------------------------------------
  // Query-param helpers
  // -------------------------------------------------------------------------
  function qp(name) {
    return new URLSearchParams(window.location.search).get(name);
  }

  // -------------------------------------------------------------------------
  // DOM refs
  // -------------------------------------------------------------------------
  const imgA       = document.getElementById("img-a");
  const imgB       = document.getElementById("img-b");
  const clipB      = document.getElementById("clip-b");
  const divider    = document.getElementById("divider");
  const scrubber   = document.getElementById("frame-scrubber");
  const frameCount = document.getElementById("frame-count");
  const labelAEl   = document.getElementById("label-a");
  const labelBEl   = document.getElementById("label-b");
  const overlayA   = document.getElementById("overlay-a");
  const overlayB   = document.getElementById("overlay-b");
  const statusEl   = document.getElementById("status");
  const canvasWrap = document.getElementById("canvas-wrap");

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------
  let frames       = [];      // manifest.frames array
  let currentFrame = 0;
  let dividerFrac  = 0.5;     // 0..1 fraction of canvas width
  let dragging     = false;

  // -------------------------------------------------------------------------
  // Error display
  // -------------------------------------------------------------------------
  function showError(msg) {
    statusEl.textContent = msg;
    console.error("[slider]", msg);
  }

  // -------------------------------------------------------------------------
  // Load manifest.json
  // -------------------------------------------------------------------------
  async function loadManifest() {
    document.body.classList.add("loading");
    let manifest;
    try {
      const resp = await fetch("manifest.json");
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      manifest = await resp.json();
    } catch (e) {
      showError(
        "Could not load manifest.json — make sure you ran render_pair.py and " +
        "are serving via serve-local.sh (not opened as a file:// URL directly)."
      );
      document.body.classList.remove("loading");
      return;
    }

    frames = manifest.frames || [];
    if (frames.length === 0) {
      showError("manifest.json has no frames.");
      document.body.classList.remove("loading");
      return;
    }

    // Apply labels (query params override manifest)
    const la = qp("label_a") || manifest.label_a || "A";
    const lb = qp("label_b") || manifest.label_b || "B";
    labelAEl.textContent  = la;
    labelBEl.textContent  = lb;
    overlayA.textContent  = la;
    overlayB.textContent  = lb;
    document.title        = `${la} vs ${lb} — Wipe Slider`;

    // Set up scrubber
    scrubber.min   = 0;
    scrubber.max   = frames.length - 1;
    scrubber.value = 0;

    document.body.classList.remove("loading");
    showFrame(0);
  }

  // -------------------------------------------------------------------------
  // Frame display
  // -------------------------------------------------------------------------
  function showFrame(idx) {
    currentFrame = Math.max(0, Math.min(frames.length - 1, idx));
    const fr = frames[currentFrame];
    imgA.src = fr.a;
    imgB.src = fr.b;
    scrubber.value = currentFrame;
    frameCount.textContent = `${currentFrame + 1} / ${frames.length}`;
  }

  // -------------------------------------------------------------------------
  // Wipe / divider logic
  //
  // Layout:
  //   #canvas-wrap is the viewport (flex, centered content).
  //   img-a fills it with object-fit:contain.
  //   #clip-b is clipped to [dividerX, right] of #canvas-wrap.
  //   img-b inside #clip-b must appear at the same size/position as img-a,
  //   so we shift it left by dividerX px using a CSS transform.
  // -------------------------------------------------------------------------

  function applyDivider(clientX) {
    const rect = canvasWrap.getBoundingClientRect();
    const x = Math.max(0, Math.min(clientX - rect.left, rect.width));
    dividerFrac = x / rect.width;

    const px = x + "px";
    divider.style.left = px;
    clipB.style.left   = px;

    // Tell img-b inside clip-b how far left to shift so it aligns with img-a
    // clip-b starts at x px from left of canvas-wrap; img-b must start at 0
    imgB.style.transform = `translateX(-${x}px)`;
    imgB.style.width     = rect.width + "px";
  }

  function resetDivider() {
    const rect = canvasWrap.getBoundingClientRect();
    applyDivider(rect.left + rect.width * dividerFrac);
  }

  // -------------------------------------------------------------------------
  // Event listeners — divider drag (mouse + touch)
  // -------------------------------------------------------------------------
  function onDragStart(e) {
    dragging = true;
    e.preventDefault();
  }

  function onDragMove(e) {
    if (!dragging) return;
    const clientX = e.touches ? e.touches[0].clientX : e.clientX;
    applyDivider(clientX);
  }

  function onDragEnd() {
    dragging = false;
  }

  divider.addEventListener("mousedown",  onDragStart);
  divider.addEventListener("touchstart", onDragStart, { passive: false });
  window.addEventListener("mousemove",   onDragMove);
  window.addEventListener("touchmove",   onDragMove, { passive: false });
  window.addEventListener("mouseup",     onDragEnd);
  window.addEventListener("touchend",    onDragEnd);

  // Click anywhere on canvas to move divider (but not on the divider itself)
  canvasWrap.addEventListener("click", function (e) {
    if (e.target === divider || divider.contains(e.target)) return;
    applyDivider(e.clientX);
  });

  // -------------------------------------------------------------------------
  // Frame scrubber
  // -------------------------------------------------------------------------
  scrubber.addEventListener("input", function () {
    showFrame(parseInt(this.value, 10));
  });

  // Keyboard: left/right arrows for frames, shift+drag hint
  window.addEventListener("keydown", function (e) {
    if (e.key === "ArrowRight") showFrame(currentFrame + 1);
    if (e.key === "ArrowLeft")  showFrame(currentFrame - 1);
  });

  // -------------------------------------------------------------------------
  // Resize — re-apply divider position so it stays at the same fraction
  // -------------------------------------------------------------------------
  window.addEventListener("resize", resetDivider);

  // -------------------------------------------------------------------------
  // Boot
  // -------------------------------------------------------------------------
  loadManifest();

  // Initial divider position (centre) — set after brief paint delay
  requestAnimationFrame(function () {
    requestAnimationFrame(resetDivider);
  });

})();
