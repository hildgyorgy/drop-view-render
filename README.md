# Drop & View Render

Native companion renderer for [Drop & View](https://github.com/hildgyorgy/drop-3d-view).

Drop & View remains the browser-based viewer, material editor and scene composer.
Drop & View Render receives a materialized `.glb` model or a portable
`.dvrender` scene package and produces a final image through Blender/Cycles.

## Current state

The repository is a native SwiftUI macOS application. It:

- accepts one or more `.glb` or `.dvrender` files by drag and drop or file picker;
- launches Blender without opening Blender's interface;
- uses Cycles and the Apple Metal GPU when available;
- restores the packaged camera, render size, sample/bounce targets, HDRI and
  top-level group visibility from `.dvrender`;
- lets the user override render quality, output destination and camera-visible
  HDRI background without disabling HDRI lighting or reflections;
- writes `<input-name>-cycles.png` next to the input;
- streams Blender output into the job UI and supports cancel and Show in Finder.

The bundled adapter currently runs a deliberate RAW benchmark configuration:
adaptive sampling and denoising are disabled. This is temporary and must become
a user-facing render preset.

The Swift sources and bundled Blender adapter live in `DropViewRender/`. No
separate Python runtime, Terminal launcher, AppleScript droplet or legacy helper
app is part of the current application.

Open `DropViewRender.xcodeproj` in Xcode to run the application.

## Requirements

- macOS on Apple Silicon
- Blender 5.2.3 LTS installed at `/Applications/Blender.app`

The adapter can also be invoked directly for development diagnostics:

```sh
/Applications/Blender.app/Contents/MacOS/Blender \
  --background --factory-startup --python-exit-code 1 \
  --python DropViewRender/Resources/render_glb.py -- model.glb
```

Optional arguments after `--`:

```text
--output result.png
--hdri environment.hdr
--hide-hdri-background
--width 1920 --height 1080
--samples 500
--bounces 6 --transmission-bounces 10
```

`--hide-hdri-background` keeps HDRI illumination, sun alignment and reflections
active while replacing the camera-visible environment image with the same
neutral background concept used by the Drop & View path tracer.

## Product direction

The production application is a native SwiftUI macOS app with:

- a minimal drag-and-drop window;
- `.dvrender` file association;
- Blender discovery and diagnostics;
- render presets and editable output settings;
- real progress, cancel and Show in Finder controls;
- Developer ID signing and notarization;
- no visible Terminal or separate Python installation.

Blender's bundled Python will execute a small `bpy` adapter. A Windows client
can follow later while preserving the same `.dvrender` contract.

See [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) for the current engineering state
and [docs/DVRENDER_FORMAT.md](docs/DVRENDER_FORMAT.md) for the package contract.

