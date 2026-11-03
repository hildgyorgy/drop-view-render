"""Run in background Blender with -- <real .dvrender>; verifies portable export."""
from pathlib import Path
import runpy
import sys
import tempfile

import bpy


source = Path(sys.argv[sys.argv.index("--") + 1]).resolve()
adapter = Path(__file__).resolve().parents[1] / "DropViewRender/Resources/render_glb.py"
with tempfile.TemporaryDirectory(prefix="dvr-prepared-test-") as directory:
    root = Path(directory)
    destination = root / "prepared.blend"
    image = root / "render.png"
    sys.argv = ["blender", "--", str(source), "--output", str(image),
                "--save-blend", str(destination), "--prepare-only",
                "--width", "64", "--height", "64", "--samples", "2",
                "--bounces", "6", "--transmission-bounces", "10",
                "--denoise", "--adaptive-sampling", "--noise-threshold", "0.03"]
    runpy.run_path(str(adapter), run_name="__main__")
    assert destination.read_bytes()[:7] == b"BLENDER"
    assert not image.exists(), "Preparation must not render or overwrite an image"
    bpy.ops.wm.open_mainfile(filepath=str(destination))
    scene = bpy.context.scene
    assert scene.camera is not None
    assert (scene.render.resolution_x, scene.render.resolution_y) == (64, 64)
    assert scene.cycles.samples == 2
    assert scene.cycles.max_bounces == 6
    assert scene.cycles.transmission_bounces == 10
    assert scene.cycles.use_denoising and scene.cycles.use_adaptive_sampling
    assert abs(scene.cycles.adaptive_threshold - 0.03) < 1e-6
    hdri = next(node.image for node in scene.world.node_tree.nodes if node.type == "TEX_ENVIRONMENT")
    assert hdri.packed_file is not None
    assert not Path(hdri.filepath).exists(), "Test must exercise an expired temporary HDRI source"
    for datablock in bpy.data.images:
        if datablock.source == "FILE" and datablock.filepath:
            assert datablock.packed_file is not None, datablock.name
    views = [space for screen in bpy.data.screens for area in screen.areas
             for space in area.spaces if space.type == "VIEW_3D"]
    assert views and all(space.region_3d.view_perspective == "CAMERA" for space in views)
    # Blender resets RENDERED on file load; exercise the same post-load entry
    # point used by the native GUI launch, without reimporting/resetting the scene.
    camera = scene.camera
    sys.argv = ["blender", "--", str(destination), "--view-prepared"]
    runpy.run_path(str(adapter), run_name="__main__")
    assert bpy.context.scene.camera == camera
    assert all(space.shading.type == "RENDERED" for space in views)
    glass = [node for material in bpy.data.materials if material.node_tree
             for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"
             and bool(node.inputs["Thin Wall"].default_value)]
    assert glass
    for node in glass:
        assert abs(node.inputs["IOR"].default_value - 1.51) < 1e-5
        assert abs(node.inputs["Roughness"].default_value - 0.01) < 1e-5
        assert abs(node.inputs["Transmission Weight"].default_value - 1) < 1e-5
    bpy.ops.render.render(write_still=True)
    assert image.exists() and image.stat().st_size > 0
    print("PASS: prepare-only, packed resources after temp cleanup, camera viewport, settings, glass, reopened render")
