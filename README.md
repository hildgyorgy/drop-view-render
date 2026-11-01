# Drop & View Render

Native companion renderer for [Drop & View](https://github.com/hildgyorgy/drop-3d-view).

Drop & View remains the browser-based viewer, material editor and scene composer.
Drop & View Render receives a materialized `.glb` model or a portable
`.dvrender` scene package and produces a final image through Blender/Cycles.

## Current state

The repository starts with the proven macOS droplet prototype in
`prototype/macos-droplet/`. It:

- accepts one or more `.glb` or `.dvrender` files by drag and drop or file picker;
- launches Blender without opening Blender's interface;
- uses Cycles and the Apple Metal GPU when available;
- restores the packaged camera, render size, sample/bounce targets, HDRI and
  top-level group visibility from `.dvrender`;
- writes `<input-name>-cycles.png` next to the input;
- shows preparation and render progress in Terminal.

The prototype currently runs a deliberate RAW benchmark configuration:
adaptive sampling and denoising are disabled. This is temporary and must become
a user-facing render preset in the native application.

## Prototype requirements

- macOS on Apple Silicon
- Blender 5.2.3 LTS installed at `/Applications/Blender.app`

Double-click `prototype/macos-droplet/Drop & View Cycles.app`, or drop a GLB or
`.dvrender` package onto it. The current app name is intentionally retained for
the proof of concept; the native successor will be named `Drop & View Render.app`.

Terminal use:

```sh
/Applications/Blender.app/Contents/MacOS/Blender \
  --background --factory-startup --python-exit-code 1 \
  --python prototype/macos-droplet/render_glb.py -- model.glb
```

Optional arguments after `--`:

```text
--output result.png
--hdri environment.hdr
--width 1920 --height 1080
--samples 500
--bounces 6 --transmission-bounces 10
```

## Product direction

The production application will be a native SwiftUI macOS app with:

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

