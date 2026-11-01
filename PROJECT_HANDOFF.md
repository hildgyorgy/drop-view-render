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
- Final output is staged beside its destination and moved into place only after
  Blender reports success and a non-empty image is verified. Cancellation
  pauses the queue and escalates from interrupt to termination if necessary.
- Plain GLB files use the bundled, CC0 Drop & View default environment.
- The importer maps exporter-selected clear glass (material extras:
  `archicad.clearGlassOverride == true`, positive transmission, absent/zero
  volume thickness) to the native Blender 5.2 Principled Thin Wall input.
  Unmarked, positive-thickness and alpha-only materials are not converted.
  This uses a scoped material-hook dispatcher wrapper restored after import;
  recheck that integration when changing the supported Blender version.
  A real interior A/B render showed Thin Wall alone still blocking direct
  HDRI illumination. Marked thin glass therefore also uses a shadow-only
  Transparent BSDF branch preserving base color and transmission weighting;
  camera/reflection shading remains Thin Wall. This is a straight-through
  approximation, not refractive caustics. Full-resolution interior user review
  confirmed the improvement on 2026-11-01.

The app now has Recommended and Custom quality profiles. Recommended preserves
source/default sample counts as a maximum and keeps bounce limits, enabling
adaptive sampling (noise threshold 0.03) and OpenImageDenoise. Custom allows
editing counts, toggling adaptive sampling/denoise and selecting noise thresholds,
and retains its settings when switching profiles. Resolution is independently overridden.
The adapter defaults to denoise ON (`--no-denoise` disables it); it uses albedo
and normal guidance, accurate prefiltering, high quality and requests GPU
acceleration. Adaptive sampling has a minimum of 32 samples (capped at the
requested maximum); disable adaptive and denoise for a fixed-sample RAW comparison.
The CLI retains fixed sampling unless `--adaptive-sampling` is passed; the app
always passes an explicit policy. `--noise-threshold` must be finite in
0.0001–1. The adapter verifies denoise, sampling policy and sample cap at runtime.
Actual per-pixel sample counts/savings are not yet measured or displayed.
An immutable per-run settings snapshot supplies the adapter arguments and stays
visible separately from next-render controls after profile/quality edits.
Recommended threshold was raised to 0.03 after a 512×321 diagnostic at 0.01
averaged 484/500 samples, giving only about 3.2% sample savings. Full-resolution
0.03 quality/time comparison is pending. CLI default threshold remains 0.01.

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
- [x] unified toolbar Render action for selected rerenders and pending jobs,
      with existing-output replacement confirmation;
- [x] monotonic elapsed/total job time in sidebar, details and final log,
      including preparation, denoise and output finalization;
- [x] PNG destination and current adapter quality arguments;
- [x] camera-visible HDRI background override that preserves environment
      lighting, reflections and sun alignment;
- [x] machine-readable Cycles sample progress in Blender's piped output;
- [ ] reliable remaining-time reporting;
- [x] Recommended/Custom quality profiles and denoise toggle backed by adapter
      arguments, with independent resolution override;
- [x] adaptive sampling toggle and noise threshold selection backed by adapter
      arguments, with explicit maximum-sample UI;
- [ ] output-format controls backed by matching adapter arguments;
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

