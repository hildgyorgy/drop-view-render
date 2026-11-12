# Drop & View Render — project handoff

Updated: 2026-11-12

## Purpose

Drop & View Render is the separate final-render companion to the Drop & View
web application. The web app composes the model, materials, camera and lighting;
this project renders the resulting GLB or `.dvrender` package through
Blender/Cycles without requiring Blender knowledge.

## Default Blender version (2026-11-12)

The user selected stable Blender 5.3.0 as the new default. The installed
`/Applications/Blender.app` reports 5.3.0 (release hash `02f0899d78e3`). macOS
adds versioned 5.3 / 5.3.0 locations before the generic application and legacy
5.2 fallback; a deliberately saved executable remains first. Windows now
searches 5.3 before 5.2 using numeric version order, accepts stable 5.3.x plus
previously supported 5.2.3+ LTS, and rejects alpha/beta/RC versions. UI/setup
instructions and repository guidance recommend 5.3.0; old release notes and
historical render evidence keep their original version numbers.

The production adapter required no behavioral change. On Blender 5.3.0, the
quality-policy test, marked thin-glass/import-hook test, packed prepared-scene
reopen/render test, and orthographic/axon projection/package render test passed.
The macOS Release build and Windows tray cross-build also passed (Windows: zero
warnings/errors); all 42 Windows core checks and four GPU policy unit tests passed.
Denoise/adaptive flags, exact sample/bounce targets, glass calibration and
.dvrender v1 remain unchanged. This source update does not replace the already
published v0.3.0 DMG or imply a new signed/notarized binary release. The pending
live Safari four-combination release acceptance remains a separate task.

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

### Web quality switches (2026-11-11)

The web RENDER panel now exposes independent DENOISE and ADAPTIVE switches,
both ON by default. `uploadBegin` accepts optional strict boolean `denoise` /
`adaptive` fields, frozen into the durable upload record and relayed through
`X-DVR-Settings` with the existing `recommended` envelope. The HTTP bridge
passes both policies to the queue; OFF selects Custom with source resolution,
sample/bounce targets and 0.03 adaptive threshold preserved. Omitted fields
retain ON/ON. Quality flags participate in staging and HTTP idempotency checks.
Both extension discovery and native status advertise `quality-controls`; the
web requires both to allow OFF, avoiding silent downgrade on older installs.
Safari and the shared Chromium extension use the same updated protocol. Windows
does not advertise this capability yet and retains its ON/ON defaults.

Verified: unsigned Xcode app/extension/helper build, upload-store smoke including
quality conflicts, five Safari protocol/Swift tests, three Chromium helper tests,
and a real four-job Cycles smoke through the Native Messaging router and HTTP
queue covering ON/ON, OFF/ON, ON/OFF and OFF/OFF. Web checks: 153 unit tests and
the two package UI smoke tests. Updated app/extension builds must be installed
and browser pages reloaded before live OFF controls are supported. No installed
app replacement, signing, release, commit or publication was performed.

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

## Windows tray prototype (2026-11-04)

`windows/` now contains a .NET 10 WinForms NotifyIcon/ApplicationContext app
(no main window), shared portable Core, Chromium stdio NativeHost, core tests,
Windows-only native host/Job Object tests, PowerShell publish/registration and
Inno Setup installer source. The common Chrome/Edge extension is copied from the
same files as macOS. Safari and a Windows HTTP listener are not included.
The user prefers a future macOS menu-bar/dropdown UI; the current SwiftUI window
was intentionally not redesigned during this Windows implementation.

The tray app owns a serial queue independently of browser-port lifetime.
Native host communication uses bounded framed JSON over a current-user-only,
per-logon-session named pipe. Native origin approval, in-memory credentials,
checksummed 64 KiB chunks, replay/full digest idempotency, package limits,
immutable Recommended settings, indexed output, cancel and reveal are implemented.
The tray exposes readiness, output/Blender choice, cancel/disconnect, opt-in
sign-in startup and quit. An app-lifetime Windows Job Object owns Blender children.
Blender 5.2.3 LTS remains external; no Python or Blender runtime is vendored.

Shared adapter `--device AUTO|CPU|METAL|OPTIX|CUDA|HIP|ONEAPI` now keeps Metal on
macOS and tries OptiX/CUDA/HIP/oneAPI then a reported CPU fallback on Windows.
Explicit unavailable GPU backends fail rather than silently changing device.
No scene/material/camera/sample/bounce policy changed.

Verified locally on macOS: all C# projects cross-build without warnings/errors;
34 core checks (36 including an actual 64×48/1-sample test-fixture Cycles render);
real named-pipe roundtrip; GPU policy unit checks; existing Blender quality and
orthographic/package smoke; baseline/current real Metal CLI smoke; actual
PowerShell publish produced self-contained Windows x64 PE executables and a ZIP.
The first standalone ortho smoke hit a transient native Metal shader-cache
exception; baseline/current CLI and the subsequent unchanged ortho smoke passed.

`.github/workflows/windows.yml` is ready to run Windows core, real Win32 Job
Object/published-host tests, publish and Inno Setup compilation/artifact upload.
It has NOT been run remotely, and no Windows UI/installer/vendor-GPU acceptance
is claimed. The prototype is unsigned. Windows 11 hardware testing and release
signing/store publication remain. See `windows/README.md` for use/build/security
limits; build products are ignored, no certificates or secrets committed.

## macOS release preparation (2026-11-11)

Initial Git audit: native HEAD `670cd30` had 14 modified tracked files (web
quality relay and tests/docs); web HEAD `74c9f83` had a clean worktree and was
already on origin/main. The public HTTPS WebGL bundle exactly matched the local
bundle (SHA-256 `677d56233bffc01f664d866a7ee394a8772bbf62b41ead0a6880705bd788ad45`).
Thus the web controls were already published, contrary to the starting assumption.

`tools/macos_release.py` now prepares Apple Silicon Release builds, stamps app /
Safari / Chromium versions, explicitly signs extension/helper/app inside-out,
checks same Developer ID team, secure timestamp, hardened runtime and no debug
entitlement, notarizes/staples app then signed DMG, verifies Gatekeeper/checksums
and publishes with GitHub CLI only from matching clean source provenance.
App Info.plist version fields now use Xcode build settings; Safari product
wording no longer says Prototype. Development signing defaults are preserved.
See `docs/MACOS_RELEASE.md` and `docs/MACOS_INSTALL.md`.

Verified this turn: unsigned Release builds (0.3.0 / 3 and 4), matching app/extension
and browser manifest versions; native handler/store smokes; 8 Safari/Chromium JS/helper tests; 153 web
unit tests; real router → native HTTP → Cycles four-combination DENOISE/ADAPTIVE
smoke with unchanged test scene targets/retry dedup. This is not live Safari
release acceptance. A pre-existing macOS 27 loadItem deprecation warning remains.

Release is pending: login Keychain has Apple Development and Apple Distribution
identities, but no Developer ID Application identity. User was asked to create
that certificate in Xcode. Notarytool Keychain credentials and GitHub CLI release
access must be validated at their steps. No public Release, signed/notarized DMG,
installed app replacement or GitHub-download acceptance has been performed yet.
Current source edits remain uncommitted until release prerequisites are resolved.

## Single Windows download (2026-11-12)

At the user's request, the public v0.3.0 Release now offers one Windows ZIP:
`DropViewRender-Windows-0.3.0.zip`, containing the previously CI-tested Setup.exe
unchanged plus `README-Windows.txt`. The standalone EXE and portable ZIP were
removed from the public assets after the installer ZIP was uploaded/verified.
Windows-SHA256SUMS.txt covers the new ZIP. The CI workflow packages/uploads only
the installer ZIP; the portable bundle remains an internal development product.
Current setup/release/README text consistently recommends stable Blender 5.3.0.
No Windows signing or live Windows GPU/browser acceptance is implied.

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
- Distribution: native SwiftUI macOS app plus a Windows 11 x64 tray prototype.
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

