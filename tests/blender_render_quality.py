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
for flags, expected in [([], False), (["--adaptive-sampling"], True),
                        (["--no-adaptive-sampling"], False)]:
    sys.argv = ["Blender", "--", "example.glb", *flags]
    assert adapter["bridge_arguments"]().adaptive_sampling == expected

scene = bpy.context.scene
scene.render.engine = "CYCLES"
for denoise, adaptive, samples in [(True, True, 37), (False, False, 37),
                                  (True, False, 37), (False, True, 1)]:
    args = SimpleNamespace(width=96, height=64, samples=37, bounces=8,
                           transmission_bounces=12, denoise=denoise,
                           adaptive_sampling=adaptive, noise_threshold=0.01)
    args.samples = samples
    adapter["configure_render"](scene, args, Path("/tmp/drop-view-quality-test.png"))
    assert scene.cycles.use_denoising == denoise
    assert scene.cycles.use_adaptive_sampling == adaptive
    assert scene.cycles.samples == samples
    assert scene.cycles.adaptive_min_samples == min(32, samples)
    assert abs(scene.cycles.adaptive_threshold - 0.01) < 1e-7
    assert scene.cycles.max_bounces == 8
    assert scene.cycles.transmission_bounces == 12
    assert (scene.render.resolution_x, scene.render.resolution_y) == (96, 64)
    assert scene.cycles.denoiser == "OPENIMAGEDENOISE"
    assert scene.cycles.denoising_input_passes == "RGB_ALBEDO_NORMAL"
    assert scene.cycles.denoising_prefilter == "ACCURATE"
    assert scene.cycles.denoising_quality == "HIGH"
for threshold in (float("nan"), float("inf"), 0, -0.1, 1.1):
    args.noise_threshold = threshold
    try:
        adapter["configure_render"](scene, args, Path("/tmp/drop-view-quality-test.png"))
    except ValueError:
        pass
    else:
        raise AssertionError(f"Accepted invalid threshold {threshold}")
print("PASS: denoise/adaptive CLI and switching, small sample cap, exact counts, invalid thresholds")
