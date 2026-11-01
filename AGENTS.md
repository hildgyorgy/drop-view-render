# Repository guidance

- Read `PROJECT_HANDOFF.md`, `README.md` and `docs/DVRENDER_FORMAT.md` before changes.
- Preserve compatibility with the `.dvrender` v1 contract produced by
  `hildgyorgy/drop-3d-view`.
- Treat `prototype/macos-droplet/` as the verified proof of concept. Keep it
  working while the native application is developed beside it.
- Target Blender 5.2.3 LTS. Do not make beta Blender versions a requirement.
- Do not bundle a separate Python runtime; Blender's own Python runs the `bpy` adapter.
- Do not vendor Blender itself without an explicit packaging and licence decision.
- Never silently reduce the requested resolution, samples or bounce counts.
- Keep UI terminology aligned with the product name: **Drop & View Render**.
- Run syntax/format checks and a small Blender smoke render after changes to the adapter.
- Do not commit rendered PNG/EXR files, Blender scratch files, secrets, signing
  certificates or notarization credentials.

