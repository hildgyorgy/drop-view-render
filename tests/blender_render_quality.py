"""Run with Blender --background --factory-startup --python-exit-code 1 --python this_file."""

from pathlib import Path
import runpy
import sys
from types import SimpleNamespace

import bpy


adapter = runpy.run_path(str(
    Path(__file__).resolve().parents[1] / "DropViewRender/Resources/render_glb.py"
))
for flags, expected in [([], True), (["--denoise"], True), (["--no-denoise"], False)]:
    sys.argv = ["Blender", "--", "example.glb", *flags]
    assert adapter["bridge_arguments"]().denoise == expected

scene = bpy.context.scene
scene.render.engine = "CYCLES"
for denoise in (True, False, True):
    args = SimpleNamespace(width=96, height=64, samples=37, bounces=8,
                           transmission_bounces=12, denoise=denoise)
    adapter["configure_render"](scene, args, Path("/tmp/drop-view-quality-test.png"))
    assert scene.cycles.use_denoising == denoise
    assert not scene.cycles.use_adaptive_sampling
    assert scene.cycles.samples == 37
    assert scene.cycles.max_bounces == 8
    assert scene.cycles.transmission_bounces == 12
    assert (scene.render.resolution_x, scene.render.resolution_y) == (96, 64)
    assert scene.cycles.denoiser == "OPENIMAGEDENOISE"
    assert scene.cycles.denoising_input_passes == "RGB_ALBEDO_NORMAL"
    assert scene.cycles.denoising_prefilter == "ACCURATE"
    assert scene.cycles.denoising_quality == "HIGH"
print("PASS: default/explicit denoise CLI, RAW switching, exact resolution/sample/bounce counts")
