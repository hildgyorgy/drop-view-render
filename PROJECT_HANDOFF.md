# Drop & View Render — project handoff

Updated: 2026-11-01

## Purpose

Drop & View Render is the separate final-render companion to the Drop & View
web application. The web app composes the model, materials, camera and lighting;
this project renders the resulting GLB or `.dvrender` package through
Blender/Cycles without requiring Blender knowledge.

## Verified renderer path

The Blender adapter was proven first in the macOS droplet and now lives as an
application resource at `DropViewRender/Resources/render_glb.py`. The old
Terminal/AppleScript droplet has been retired from this repository.

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
- The native app streams preparation activity, Blender output, final path and
  READY into its job UI.

The current adapter deliberately forces fixed samples with adaptive sampling
OFF and denoising OFF for a temporary image-quality benchmark. It verifies
those Blender properties at runtime. Production defaults still need a decision.

## Current files

- `DropViewRender.xcodeproj` — native macOS application project.
- `DropViewRender/` — SwiftUI job UI, package preview validation,
  Blender discovery and subprocess queue.
- `DropViewRender/Resources/render_glb.py` — package decoder, Blender import,
  Cycles/Metal configuration, camera/HDRI/visibility restoration and output.
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

Complete and harden the native SwiftUI application and bundled Python adapter:

- [x] Xcode project and stable bundle identifier;
- [x] drag-and-drop and Open panel for GLB/`.dvrender`;
- [x] Blender executable discovery and initial diagnostics;
- [x] subprocess launch with streamed stdout/stderr;
- [x] job state UI, Cancel and Show in Finder;
- [x] PNG destination and current adapter quality arguments;
- [x] camera-visible HDRI background override that preserves environment
      lighting, reflections and sun alignment;
- [ ] reliable machine-readable Cycles progress and remaining-time reporting;
- [ ] user-facing adaptive sampling, denoise and output-format controls backed
      by matching adapter arguments;
- [ ] automated package-reader tests and a native-app smoke-render workflow;
- [ ] signing, notarization and release packaging decisions.

## Repository split checklist

- [x] Import the verified renderer into the new project.
- [x] Add independent README, handoff, repository guidance and format spec.
- [x] Initialize local Git repository and make the initial commit.
- [x] Create and push the public GitHub repository:
      `https://github.com/hildgyorgy/drop-view-render`.
- [x] Add a compatibility link in `drop-3d-view/tools/cycles/README.md`.
- [x] Remove the old renderer copy from Drop & View after the new remote and
      a smoke render were verified. The removed `.app` bundle was moved to the
      macOS Trash as a recoverable precaution.
- [x] Retire the copied Terminal/AppleScript droplet after the native app
      completed a full-quality `.dvrender` render.

