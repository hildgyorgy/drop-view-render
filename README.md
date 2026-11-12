# Drop & View Render

Native companion renderer for [Drop & View](https://github.com/hildgyorgy/drop-3d-view).

Drop & View remains the browser-based viewer, material editor and scene composer.
Drop & View Render receives a materialized `.glb` model or a portable
`.dvrender` scene package and produces a final image through Blender/Cycles.

## Current state

The repository is a native SwiftUI macOS application. It:

- accepts one or more `.glb` or `.dvrender` files by drag and drop or file picker;
- displays the embedded scene thumbnail beside each `.dvrender` job; older
  packages and plain GLB use a placeholder without generating a preview render;
- launches Blender without opening Blender's interface;
- uses Cycles and the Apple Metal GPU when available;
- restores the packaged camera, render size, sample/bounce targets, HDRI and
  top-level group visibility from `.dvrender`;
- lets the user override render quality, output destination and camera-visible
  HDRI background without disabling HDRI lighting or reflections;
- writes `<input-name>-cycles.png` next to the input through a temporary staging
  file, so a failed or cancelled render cannot leave a partial final image;
- streams Blender output into the job UI and supports cancel and Show in Finder;
- uses the same toolbar Render button for initial renders and rerenders of the
  selected finished job; rerenders and existing-file collisions automatically
  use the next free `-001`, `-002`, … filename, preserving previous images;
- shows live elapsed time and retains total job time (including Blender startup,
  import, rendering, denoising and output finalization) after completion or cancellation.

Render quality has two profiles: **Recommended** keeps the package/default
sample count as a maximum, preserves bounce limits and enables adaptive sampling
(noise threshold 0.03) and OpenImageDenoise. **Custom** lets the user edit those
counts, toggle denoising and adaptive sampling, and select a noise threshold.
Disable both switches for a fixed-sample RAW comparison. Switching profiles
preserves Custom values. Resolution has its own independent override.
Adaptive sampling stops clean pixels early; minimum samples is 32 or the
requested maximum if lower. A lower noise threshold asks for a cleaner image.
No actual per-pixel sample statistics or savings are currently reported.
Each run retains an immutable settings snapshot, separate from next-render
controls. That snapshot also supplies the adapter arguments and is written to
the job log, so changing profiles cannot relabel a previous result.
OIDN uses albedo/normal guidance, accurate
prefiltering and high quality, with GPU acceleration requested when available.

Exporter-selected clear glass (`material.extras.archicad.clearGlassOverride`
equal to `true`) with positive glTF transmission and no positive
`KHR_materials_volume` thickness uses Blender's native Principled BSDF
**Thin Wall** mode. Unmarked materials, positive-thickness glass and alpha-only
transparency retain their imported behavior. Eligible marked thin glass gets
Cycles-only calibration: **IOR 1.51, roughness 0.01, transmission 1.0**. These
three inputs override imported constants or texture links. Base color, normal
maps and unrelated material properties remain imported as supplied. The
shadow-only branch uses the calibrated transmission and preserves color tint.
The same policy applies to plain GLB, dropped/opened `.dvrender` files and browser
submissions, without changing source bytes or the web viewer. Each conversion is listed
in Blender output. The marker is already preserved in `.dvrender` v1's GLB.
Marked thin glass also gets a shadow-only Transparent BSDF branch, tinted by
its base color and weighted by its transmission (including linked textures).
This straight-through approximation admits direct environment light into
interiors; it does not reproduce refractive caustics. Camera/reflection rays
keep the imported Thin Wall surface.

The Swift sources and bundled Blender adapter live in `DropViewRender/`. No
separate Python runtime, Terminal launcher, AppleScript droplet or legacy helper
app is part of the current application.

Open `DropViewRender.xcodeproj` in Xcode to run the application.

Orthographic/axon snapshots exported by the updated web app preserve the exact
camera frame and zoom. Older packages without frustum bounds use an estimated
fit; re-export them for precise framing. Changing only output pixel dimensions
at the same aspect keeps the frame; changing aspect preserves vertical coverage.

## Render directly from the browser

Run this app, then choose **i → RENDER WITH BLENDER → RENDER → CONNECT** in the updated Drop & View
web app and approve the connection. **RENDER** sends the current scene directly
to Cycles, keeping its dimensions, sample maximum and bounce limits. DENOISE and
ADAPTIVE are ON by default and can be independently switched off with updated
native/extension builds. Adaptive sampling uses threshold 0.03; OFF uses fixed
sampling. Each job keeps its submitted settings even if controls later change.
The browser shows progress/time, **CANCEL**, and **SHOW IN FOLDER**
when finished. While rendering, compose another camera and press **RENDER** to
queue another snapshot. The job selector keeps earlier renders accessible. Other
queued native jobs are not started by a browser submission.

Images are saved to **Downloads / Drop & View Render**, with automatic numbered
filenames preserving existing images. The native Browser Bridge menu revokes
connections. **SAVE PACKAGE** and the manual native workflow remain available.
See [the bridge contract](docs/BROWSER_BRIDGE.md) for limits, tests and browser
compatibility. A Windows tray prototype is now included; see below.

## Browser extensions

**CONNECT** automatically detects the Drop & View Render extension in Safari,
Chrome or Edge when you press CONNECT. It does not pair automatically, start a
render or fall back silently. There is no web transport selector or direct
browser HTTP client. Diagnostics use the detected extension as well.

All extensions send acknowledged 64 KiB chunks, stage on disk and stream to the
same authenticated native loopback HTTP queue. The web page makes no localhost
HTTP request in extension mode. Keep Drop & View Render running.

Safari's signed extension is embedded in the app; enable it and website access
in Safari settings. For Chrome/Edge, the app includes a shared Manifest V3
extension and compiled native messaging helper. Use **Browser Bridge → Set Up
Chrome / Edge…**, then load the extension folder shown by Finder through the
browser's **Load unpacked** action. This is a developer prototype; store publishing
and release installation remain separate work. Registration is per macOS user,
only for installed browsers; repeat it if the app moves. Live Edge upload,
FINISHED status, indexed rerender, CANCELLED and Finder reveal were verified.
Chrome is not installed on the test Mac, so a separate live Chrome check remains.

Details: [Chrome / Edge setup](docs/CHROMIUM_NATIVE_MESSAGING.md),
[Safari setup and shared upload protocol](docs/SAFARI_NATIVE_MESSAGING.md).

## macOS release

Developer ID signing, notarization, DMG packaging and GitHub Release commands
are documented in [the release guide](docs/MACOS_RELEASE.md). The local pipeline
checks app/extension/helper signatures and matching versions before distribution.
[Installation instructions](docs/MACOS_INSTALL.md) describe the final Safari flow.
[Version 0.3.0](https://github.com/hildgyorgy/drop-view-render/releases/tag/v0.3.0)
is Developer ID signed and notarized; its published DMG was downloaded through
Safari and the installed app passed signature, stapling and Gatekeeper checks.
Live Safari render acceptance is still pending.

## Windows tray prototype

The `windows/` folder contains a Windows 11 x64 background companion with a tray
icon and no main window. Chrome/Edge and the webapp supply scene/queue controls.
The tray provides status, Blender/output selection, cancellation, browser revoke,
optional sign-in startup and Quit. It uses the same `.dvrender` v1 and Blender
adapter, with NVIDIA OptiX/CUDA, AMD HIP, Intel oneAPI discovery and CPU fallback.
Blender 5.3.0 is the default external renderer (5.2.3 LTS remains compatible).
No Safari component is needed.

Download the [Windows installer (.exe)](https://github.com/hildgyorgy/drop-view-render/releases/download/v0.3.0/DropViewRender-Windows-0.3.0-Setup.exe)
for normal installation. The optional portable ZIP contains the same app but
requires manual browser-host registration; you do not need both downloads.
The self-contained .NET 10 bundle needs no separate .NET installation.
The Windows GitHub build, native host/process tests and installer compilation
passed. These are unsigned prototypes; real Windows tray/browser/GPU render
acceptance remains pending.
See [Windows setup/build instructions](windows/README.md).

## View in Blender

Select a valid job and use **View in Blender** in its **Output** section, beside
Show in Finder. The app prepares a self-contained `.blend` without rendering a
new PNG, then opens it in a new instance of the selected Blender.app. Camera
view and Cycles Rendered shading are set after loading. An existing Blender
workspace is not replaced.

Rendered jobs use their last-run settings; submitted jobs waiting in the browser
queue use their accepted settings; other new jobs use current settings. The
source file is read again, so external source edits or a changed adapter can
change the prepared scene. This is not a stored historical Blender snapshot.
Textures/HDRI are packed before temporary resources are removed. The `.blend`
is kept under the app's **Caches / BlenderViews** folder; use Blender **Save As**
to keep a permanent project. Cache scenes are not deleted on app quit.

Preparation is disabled during rendering; toolbar Cancel also cancels scene
preparation. Browser jobs submitted during preparation wait. The viewport has
its own sampling policy; F12 renders using the saved final settings. Preview
mode does not change source files or the `.dvrender` v1 contract.

## Requirements

- macOS on Apple Silicon
- Stable [Blender 5.3.0](https://www.blender.org/releases/5-3/) installed at `/Applications/Blender.app`
  (Blender 5.2.3 LTS remains compatible).

Automatic discovery prefers versioned Blender 5.3 installations, then the standard
Blender.app location and the legacy 5.2 location. An explicitly chosen Blender
keeps priority. No Blender or separate Python runtime is bundled.

The adapter can also be invoked directly for development diagnostics:

```sh
/Applications/Blender.app/Contents/MacOS/Blender \
  --background --factory-startup --python-exit-code 1 \
  --python DropViewRender/Resources/render_glb.py -- model.glb
```

Optional arguments after `--`:

```text
--output result.png
--save-blend prepared.blend --prepare-only
--hdri environment.hdr
--hide-hdri-background
--width 1920 --height 1080
--samples 500
--device AUTO
--bounces 6 --transmission-bounces 10
--denoise / --no-denoise
--adaptive-sampling / --no-adaptive-sampling
--noise-threshold 0.01
```

`--hide-hdri-background` keeps HDRI illumination, sun alignment and reflections
active while replacing the camera-visible environment image with the same
neutral background concept used by the Drop & View path tracer.

Denoising is enabled by default; pass `--no-denoise` for RAW output. These are
local rendering options and do not change the `.dvrender` v1 format.
The CLI keeps fixed sampling by default for compatibility; the native app
passes adaptive sampling explicitly. Requested sample counts are never
rewritten: with adaptive sampling they are the maximum per pixel.

Plain GLB renders use the bundled Drop & View default environment unless an
HDRI is supplied explicitly. The bundled `backdrop.hdr` is the **Pure Skies**
environment from [Poly Haven](https://polyhaven.com), distributed under CC0.

## Product direction

The production application is a native SwiftUI macOS app with:

- a minimal drag-and-drop window;
- `.dvrender` file association;
- Blender discovery and diagnostics;
- render presets and editable output settings;
- real progress, cancel and Show in Finder controls;
- Developer ID signing and notarization;
- no visible Terminal or separate Python installation.

Blender's bundled Python will execute a small `bpy` adapter. The Windows tray prototype
preserves the same `.dvrender` contract.

See [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) for the current engineering state
and [docs/DVRENDER_FORMAT.md](docs/DVRENDER_FORMAT.md) for the package contract.

