"""Blender --background --python-exit-code 1 --python this.py -- real.dvrender.

Compare Blender projection with Three.js orthographic math, then smoke-render
a real package through the production main path. Outputs stay in a temp folder.
"""
import json
from pathlib import Path
import runpy
import struct
import sys
import tempfile

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

adapter = Path(__file__).resolve().parents[1] / "DropViewRender/Resources/render_glb.py"
api = runpy.run_path(str(adapter))
scene = bpy.context.scene
saved = {
    "projection": "ortho", "position": [15, 10, 15], "target": [0, 2, 0],
    "up": [0, 1, 0], "zoom": 2.5, "fov": None,
}
for projection, up in (("ortho", [0, 1, 0]), ("axon", [0, 1, 0]), ("ortho", [0, 0, -1])):
    for width, height in ((160, 90), (90, 160), (100, 100)):
        aspect = width / height
        # Non-default, asymmetric frustum exercises imported framing too.
        frame = {"left": 2 - 6 * aspect, "right": 2 + 6 * aspect, "bottom": -8, "top": 4}
        saved.update(projection=projection, up=up, orthographic=frame)
        scene.render.resolution_x = width
        scene.render.resolution_y = height
        scene.render.resolution_percentage = 100
        scene.render.pixel_aspect_x = scene.render.pixel_aspect_y = 1
        # Deliberately unrelated model bounds: explicit frame must win.
        camera = api["create_package_camera"](scene, {"camera": saved},
                                               Vector((-500, -500, -500)), Vector((500, 500, 500)), aspect)
        bpy.context.view_layer.update()
        orientation = camera.rotation_quaternion
        origin = api["gltf_to_blender"](saved["position"])
        for expected_x, expected_y in ((0, 0), (1, 1), (0.5, 0.5), (0.2, 0.8)):
            x = 2 + (expected_x - 0.5) * (frame["right"] - frame["left"]) / saved["zoom"]
            y = -2 + (expected_y - 0.5) * 12 / saved["zoom"]
            point = origin + orientation @ Vector((x, y, -20))
            actual = world_to_camera_view(scene, camera, point)
            assert abs(actual.x - expected_x) < 1e-5, (projection, width, height, actual)
            assert abs(actual.y - expected_y) < 1e-5, (projection, width, height, actual)
        bpy.data.objects.remove(camera, do_unlink=True)

# Legacy packages remain readable and now match the default viewer aspect fit.
saved.pop("orthographic")
for aspect in (2, 0.5):
    scene.render.resolution_x, scene.render.resolution_y = (100, 50) if aspect == 2 else (50, 100)
    camera = api["create_package_camera"](scene, {"camera": saved}, Vector((0, 0, 0)), Vector((10, 5, 3)), aspect)
    bpy.context.view_layer.update()
    corners = camera.data.view_frame(scene=scene)
    assert abs(max(p.y for p in corners) - min(p.y for p in corners)
               - 14.4 / min(aspect, 1) / saved["zoom"]) < 1e-5
    bpy.data.objects.remove(camera, do_unlink=True)

for frame in ({}, {"left": 0, "right": 0, "top": 1, "bottom": -1},
              {"left": -1, "right": float("nan"), "top": 1, "bottom": -1}):
    try:
        api["create_package_camera"](scene, {"camera": {**saved, "orthographic": frame}},
                                     Vector((0, 0, 0)), Vector((1, 1, 1)))
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid frame accepted")

source = Path(sys.argv[sys.argv.index("--") + 1]).read_bytes()
length = struct.unpack("<I", source[8:12])[0]
manifest = json.loads(source[12:12 + length])
saved.update(projection="axon", up=[0, 1, 0], zoom=1,
             orthographic={"left": -10, "right": 10, "top": 15, "bottom": -15})
manifest["viewSession"]["camera"] = saved
manifest["renderSize"] = {"width": 32, "height": 48}
encoded = json.dumps(manifest).encode()
with tempfile.TemporaryDirectory(prefix="dvr-ortho-test-") as directory:
    package = Path(directory) / "ortho.dvrender"
    output = Path(directory) / "ortho.png"
    package.write_bytes(b"DVRENDER" + struct.pack("<I", len(encoded)) + encoded + source[12 + length:])
    sys.argv = ["blender", "--", str(package), "--output", str(output), "--samples", "1", "--no-denoise"]
    api["main"]()
    assert output.stat().st_size > 0
    assert scene.camera.data.type == "ORTHO"
    assert abs(scene.camera.data.ortho_scale - 30) < 1e-5
    assert (scene.render.resolution_x, scene.render.resolution_y) == (32, 48)
print("PASS: orthographic/axon projections, landscape/portrait/square, zoom, off-centre, legacy, validation, package render")
