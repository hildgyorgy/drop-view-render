# Drop & View Render — project handoff

Updated: 2026-11-01

## Purpose

Drop & View Render is the separate final-render companion to the Drop & View
web application. The web app composes the model, materials, camera and lighting;
this project renders the resulting GLB or `.dvrender` package through
Blender/Cycles without requiring Blender knowledge.

## Verified prototype

The working macOS proof of concept was copied from
`drop-3d-view/tools/cycles/` to `prototype/macos-droplet/` without removing the
source copy yet.

Verified on an Apple M1 Max with Blender 5.2.3:

- Metal device detection selected the 32-core Apple GPU.
- GLB import, embedded materials/textures, perspective camera, HDRI and saved
  sun alignment worked.
- `.dvrender` v1 restored its materialized GLB, perspective or orthographic
  camera, model centering, top-level group visibility, pixel dimensions,
  sample/bounce targets and packaged HDRI.
- The brightest HDRI point is aligned to the saved sun controls without adding
  a second Sun lamp.
- A 3456 × 2168 / 500-sample architectural image completed in roughly two to
  four minutes on the M1 Max, depending on settings and scene state.
- Terminal reports preparation activity, elapsed time, render progress when
  Blender exposes sample statistics, final path and READY.

The current adapter deliberately forces fixed samples with adaptive sampling
OFF and denoising OFF for a temporary image-quality benchmark. It verifies
those Blender properties at runtime. Production defaults still need a decision.

## Current files

- `prototype/macos-droplet/render_glb.py` — package decoder, Blender import,
  Cycles/Metal configuration, camera/HDRI/visibility restoration and output.
- `prototype/macos-droplet/Render with Cycles.command` — Blender discovery,
  Terminal workflow, activity display and Finder reveal.
- `prototype/macos-droplet/Drop & View Cycles.applescript` — file chooser and
  launcher source.
- `prototype/macos-droplet/Drop & View Cycles.app` — compiled proof-of-concept droplet.
- `docs/DVRENDER_FORMAT.md` — v1 interoperability contract.

## Product decisions

- Product name: **Drop & View Render**.
- Repository name: `drop-view-render`.
- Final renderer: Blender/Cycles; Metal on Apple Silicon.
- Distribution target: native SwiftUI macOS application first, Windows later.
- No localhost server, browser extension or browser-based background queue.
- The Drop & View in-app path tracer remains an interactive preview; this app
  handles final rendering.
- The client should not expose Terminal, Python or Blender UI in normal use.
- Blender remains an external prerequisite initially. Its bundled Python runs
  the adapter; no separately packaged Python is required.

## Intended native macOS workflow

1. Drop one or more GLB/`.dvrender` files onto the app.
2. Inspect jobs and optionally override resolution, samples, denoise/adaptive
   sampling, output format and destination.
3. Start or cancel rendering.
4. Show real Blender/Cycles progress and elapsed/remaining time.
5. Reveal the completed PNG/EXR in Finder.

The `.dvrender` package supplies authoritative scene defaults. Plain GLB uses
exported Drop & View camera/sun metadata when present, otherwise automatic
framing and a neutral/default environment.

## Next engineering milestone

Create the native SwiftUI shell without replacing the verified Python adapter:

- Xcode project and stable bundle identifier;
- drag-and-drop and Open panel for GLB/`.dvrender`;
- Blender executable discovery and actionable diagnostics;
- subprocess launch with streamed stdout/stderr;
- job state/progress UI, Cancel and Show in Finder;
- output and quality controls mapped to adapter arguments.

Only after this shell works should the Terminal droplet be retired or renamed.

## Repository split checklist

- [x] Copy verified prototype to the new project.
- [x] Add independent README, handoff, repository guidance and format spec.
- [x] Initialize local Git repository and make the initial commit.
- [x] Create and push the public GitHub repository:
      `https://github.com/hildgyorgy/drop-view-render`.
- [ ] Add a compatibility link in `drop-3d-view/tools/cycles/README.md`.
- [ ] Remove the old prototype copy from Drop & View after the new remote and
      a smoke render are verified.

