# Drop & View Render — project handoff

Updated: 2026-11-02

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
  On 2026-11-02, user requested a Cycles-only clear-window calibration:
  IOR 1.51, roughness 0.01, transmission 1.0. Applied during import to all
  eligible marked thin glass, replacing links only on these three inputs.
  Base color/normal links are preserved; the existing shadow-only branch
  uses the calibrated transmission. Web materials and source package bytes
  stay unchanged. File drops and browser jobs share this import path.
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
0.03 interior review retained good quality in about 4 minutes versus 8:21 RAW;
an exterior completed in 43 seconds. CLI default threshold remains 0.01.

## Browser render milestone (2026-11-02)

The app automatically listens on `127.0.0.1:43127`; the web FILE → EXPORT
CONNECT action requests native approval, then polls origin-bound authenticated
status. Sessions are memory-only and revocable from the native Browser Bridge
menu. RENDER now uses the shared web exporter, streams a validated immutable
package to the bridge, starts only that native job and reports progress/time.
New camera snapshots can be submitted while rendering; the browser queue runs
serially with immutable accepted settings and a web job selector. CANCEL targets
the selected active or waiting job. SHOW IN FOLDER explicitly activates Finder
and reveals a finished image. Recommended
quality preserves scene targets; outputs go to Downloads / Drop & View Render
with collision-safe numbering. Origin-bound idempotency prevents duplicate jobs
on retried uploads. Inputs are session-owned temporary files; normal quit removes
them after render shutdown. Full contract/limits/tests: `docs/BROWSER_BRIDGE.md`.
Manual file rendering and the adapter are unchanged.
The previous no-localhost product decision is superseded by this approved design.

## View in Blender (2026-11-03)

The native job Output section now offers View in Blender. The production adapter
accepts `--save-blend <path> --prepare-only`, sharing all normal preparation and
quality arguments, packing image resources before saving. This does not render
or overwrite a PNG. Native preparation is asynchronous, cancellable and included
in app-quit cleanup; it temporarily prevents rendering. Accepted browser jobs
wait until it finishes. Last-run settings take precedence over next-render edits.
The adapter's `--view-prepared` entry point only restores camera/Rendered viewport
state after the saved scene is loaded; Blender resets rendered shading on load.
The selected Blender.app is launched as a new instance; existing work is preserved.
Packed scenes live in app Caches/BlenderViews with unique per-open directories,
retained across app quit; Save As is needed for permanent projects. Inputs are
reread on demand, so this is not an exact archive of a past render if the source
or adapter changed. No webapp or scene contract changes were needed.

Checks: `tests/blender_prepared_scene.py` reopens a real packaged scene after
its temporary HDRI is removed, checks packed resources/camera/settings/glass,
then performs a small render. `tests/BlenderViewSmoke.swift` covers native
preparation, duplicate-click/removal guards, no PNG creation and quit cancellation.

## Orthographic framing fix (2026-11-03)

The web view snapshot now includes optional unzoomed `camera.orthographic`
bounds. Cycles uses their vertical span/zoom with explicit VERTICAL sensor fit
and preserves off-centre framing, independently of model bounds. Previous code
guessed scale from geometry and treated the same scale as the long image side,
producing different crops. Legacy v1 frames remain readable with default-fit
estimation and a re-export warning. `tests/blender_orthographic_camera.py`
compares Blender projected positions with Three.js orthographic math for
landscape/portrait/square, ortho/axon, zoom/off-centre/up-vector cases and renders
a real temporary package.

## Extension-only web connection (2026-11-04)

User confirmed the Safari extension connection works and authorized removal of
the explicit browser HTTP path. The web transport selector and direct HTTP
client were removed. CONNECT always discovers/uses the installed browser
extension; missing extensions prompt install/enable/reload or SAVE PACKAGE.
The native loopback HTTP relay remains unchanged behind the extensions, along
with its queue/authentication/validation. Earlier manual HTTP milestones below
are historical. Safari confirmation is user-reported, not a new automated live run.

## Safari Native Messaging chunked transfer (2026-11-04)

The signed embedded extension now supports pair/status/job/cancel/reveal and
64 KiB acknowledged SHA-256 upload chunks, private disk staging and bounded
retry/abort. The webapp explicitly selects HTTP (default) or SAFARI EXTENSION.
Safari page -> content script -> background -> Swift handler -> native URLSession
file upload to the existing loopback service -> existing RenderQueueModel queue.
The browser makes no localhost HTTP fetch on the Safari path; the containing app
must run. No App Group/new queue is introduced, and HTTP remains usable.

Native store/handler tests, four JS integration tests, 153 web unit tests, four
WebKit smoke tests, signed/unsigned builds, actual Cycles queue render and
same-submission dedup passed. A 256 MiB staging stress run peaked at ~8.4 MiB RSS
for the standalone harness. Real Safari extension transfer produced a Finished
3456×2168 render in 7 seconds with explicitly selected 1 test sample (restored to
500 afterwards). A stale background web status prompted forced manual refresh
and visibility/focus refresh improvements; final live UI refresh/cancellation
and public HTTPS deployment remain acceptance checks. See
`docs/SAFARI_NATIVE_MESSAGING.md` for architecture, limits, signing and evidence.

## Chrome / Edge Native Messaging and automatic detection (2026-11-04)

The app now bundles a shared MV3 Chromium extension and a signed command-line
`DropViewRenderNativeHost`. The helper reuses SafariNativeRouter/UploadStore,
validates a pinned extension caller ID, and speaks bounded length-prefixed stdio.
A persistent native port serves the chunk stream. Xcode copies the same
content/protocol JS into both extensions, with no vendored runtime.
Browser Bridge → Set Up Chrome / Edge writes user-level native host manifests
only for installed browsers and shows the bundled extension folder. Local testing
uses Load unpacked; publishing/store IDs/release installation are not done.
The embedded public key pins dev ID jfbkhccnkpadgimkmcnppodfoccadelm.

Web CONNECT defaults to AUTOMATIC (EXTENSION), using a bounded local discovery
message to distinguish Safari/Chromium, then normal native pairing. HTTP (MANUAL)
remains explicit. Discovery never pairs or launches the helper. Common diagnostics
now use the detected transport. No automatic HTTP fallback or renderer changes.

Actual Edge acceptance: user-approved developer load + native registration,
automatic detection, pairing, 1512×1774 four-sample render FINISHED in 6 seconds;
500-sample cap rerenders FINISHED in 10 seconds each with indexed filenames;
next submission CANCELLED; SHOW IN FOLDER selected the correct PNG in Finder.
Sample field restored to 500. The native helper also passed real Cycles queue,
retry/dedup and framed message tests. Chrome itself is absent on this Mac;
Chrome live acceptance and public HTTPS deployment remain to verify.
See `docs/CHROMIUM_NATIVE_MESSAGING.md` for packaging, limits and tests.

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
- The native app owns a loopback-only browser bridge for approved renders.
  A Safari Native Messaging prototype now stages chunked uploads and relays
  them natively to that same queue; direct browser HTTP transport is retired. See `docs/BROWSER_BRIDGE.md`
  and `docs/SAFARI_NATIVE_MESSAGING.md`.
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
- [x] optional v1 manifest JPEG thumbnail (max 640 pixels/256 KiB), captured by
      the web exporter and displayed in the job list; legacy files use an icon;
- [x] Blender executable discovery and initial diagnostics;
- [x] subprocess launch with streamed stdout/stderr;
- [x] job state UI, Cancel and Show in Finder;
- [x] unified toolbar Render action for selected rerenders and pending jobs,
      with automatic indexed output filenames (`-001`, `-002`, …) on rerenders
      or existing-file collisions; explicit Save-panel replacement remains possible;
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

