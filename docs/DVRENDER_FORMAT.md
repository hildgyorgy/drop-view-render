# `.dvrender` v1 interoperability contract

The authoritative producer is the Drop & View web application. Drop & View
Render is a consumer. This document describes the flattened v1 package used by
the current applications; it is not a generic glTF extension.

## Binary layout

All offsets are byte offsets from the start of the file.

| Offset | Length | Content |
| ---: | ---: | --- |
| 0 | 8 | ASCII magic `DVRENDER` |
| 8 | 4 | little-endian unsigned manifest length |
| 12 | manifest length | UTF-8 JSON manifest |
| following | variable | resources concatenated in manifest order |

The `lengths` array contains each resource byte length. Resource 0 is always a
complete GLB 2.0 file whose first four bytes are `glTF`. The package may contain
one optional Radiance `.hdr` resource after it. No alignment padding exists
between resources.

## Manifest

Representative shape:

```json
{
  "version": 1,
  "fileName": "building.glb",
  "viewSession": {},
  "renderSize": { "width": 3456, "height": 2168 },
  "renderJob": {
    "samples": 500,
    "bounces": 6,
    "transmissiveBounces": 10
  },
  "producer": {
    "appVersion": "2.0.0",
    "rendererRevision": "webgl-photo-3",
    "hdriId": "sha256:..."
  },
  "environment": {
    "name": "backdrop.hdr",
    "resource": 1
  },
  "lengths": [12345678, 2345678]
}
```

`renderSize`, `renderJob` and `environment` may be `null` in compatible older
packages. Current newly exported packages include them. Current v1 packages
must include valid `viewSession` and `producer` objects.

### Optional thumbnail

The manifest may include `thumbnail: { "mimeType": "image/jpeg", "width": 640,
"height": 401, "data": "<base64 JPEG bytes>" }`. This is a small normal-viewport
scene preview, not an accumulated render. The longer side is at most 640 pixels,
aspect ratio is preserved and the JPEG is at most 256 KiB before base64 encoding.
It counts toward the existing 4 MiB manifest limit, not the resource table.
Binary resources remain exactly the GLB and optional HDRI. Older readers ignore
this optional field; older packages without it remain valid. Invalid thumbnails
are ignored by the native viewer without preventing the render. No SVG, external
URL or arbitrary content is loaded as a preview.

## View session

`viewSession.version` is 1 and contains:

- `camera`: projection (`perspective`, `axon` or `ortho`), optional preset,
  position, quaternion, up vector, orbit target, zoom and perspective FOV;
- `displayMode` and `navigationMode`;
- `groups`: stable top-level session keys and visibility booleans;
- `selectedIds`: reserved selection identifiers; currently normally empty;
- `section`: axis, normal, constant and enabled flag;
- `settings`: viewer controls including sun angle/height, camera FOV,
  transparency, fly speed, window lights, shadow and section settings.

The Drop & View producer refuses export while SECTION is enabled.

For `axon` and `ortho`, new producers also include optional
`camera.orthographic: { left, right, top, bottom }`: the actual Three.js frustum
bounds **before zoom**, in model units. Bounds must be finite with `right > left`
and `top > bottom`; `camera.zoom` must be positive. Effective vertical span is
`(top - bottom) / zoom`. The centre is `((left + right)/2, (top + bottom)/2)`.
The exported render aspect matches the frustum aspect. The consumer uses vertical
sensor fit; an intentional output aspect override preserves the vertical span
and expands/crops horizontally. This is a backward-compatible v1 addition.
Legacy snapshots without these bounds remain readable using an estimated default
fit, with a log warning; exact custom framing requires re-export. Both file drops
and browser submissions use this same camera conversion.

## Limits and validation

- package size: maximum 2 GiB;
- manifest: maximum 4 MiB;
- resources: one GLB plus at most one HDRI;
- HDRI: maximum 256 MiB and 32 million pixels in the web producer;
- render dimensions: 1–16384 pixels per side;
- samples: 1–100000;
- regular and transmissive bounces: 1–64;
- filenames must not contain path separators, control characters, `.` or `..`.

Consumers must validate all lengths before extraction and must reject trailing,
truncated or aliased resources. The bundled Python adapter extracts resources
to a fresh temporary directory and does not trust packaged filenames as paths.

## Deliberately absent

Flattened v1 contains no separate original GLB, Workbench edit history,
`workbench` manifest field or `resolvedModel` field. Packages containing those
legacy experimental fields are intentionally rejected. Renderer program code,
accumulated samples, final PNG/EXR and Blender scene data are not embedded.

The GLB at resource 0 is already materialized: all applied Material Workbench
changes are real glTF materials, textures and UV data.

## Clear glass material policy

The Archicad exporter can explicitly mark materials with
`materials[i].extras.archicad.clearGlassOverride: true`. Drop & View preserves
this marker in the materialized GLB; no new manifest field or v1 change is
needed. The renderer enables Blender's native Thin Wall mode only for marked
materials with positive `KHR_materials_transmission.transmissionFactor` and
absent/zero `KHR_materials_volume.thicknessFactor`. Unmarked materials and
positive-thickness volumes retain their imported shading. Alpha blending or
a material/object name alone never identifies clear glass.
The consumer calibrates eligible marked thin glass in Blender memory to
IOR 1.51, roughness 0.01 and transmission 1.0, overriding imported values/links
only on those three Principled inputs. This is a Cycles rendering policy, not a
v1 format change or a rewrite of the materialized GLB. Other material inputs,
including base color and normal links, remain intact. The web viewer keeps its
own material settings. This calibration also applies to eligible marked glass
with a source transmission below 0.98; it is an explicit clear-window preset,
not a general transparency adjustment for arbitrary materials.
The marked thin-glass policy also includes colored, transmission-weighted
transparency for shadow rays, to admit direct HDRI light into interiors.
Camera and reflection rays retain the imported Thin Wall surface. Shadow
refraction/caustics are approximated; no source GLB or package bytes are changed.

