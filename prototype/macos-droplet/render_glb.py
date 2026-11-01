"""Render a GLB with Cycles from Blender's background mode.

It accepts plain GLB files and Drop & View .dvrender packages, restoring the
packaged scene state without opening Blender's interface.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import struct
import sys
import tempfile
import threading
import time
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


MAX_PACKAGE_BYTES = 2 * 1024 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_RESOURCES = 2


class RenderProgress:
    """Keep one live progress line in an interactive Terminal."""

    BAR_WIDTH = 28
    SAMPLE_PATTERN = re.compile(r"\bSample\s+(\d+)/(\d+)\b")
    REMAINING_PATTERN = re.compile(r"\bRemaining:\s*([^|]+)")

    def __init__(self) -> None:
        self.enabled = sys.stdout.isatty()
        self.started_at = 0.0
        self.status = "Starting renderer"
        self.sample = None
        self.sample_total = None
        self.remaining = None
        self.stop_event = threading.Event()
        self.thread = None

    @staticmethod
    def duration(seconds: float) -> str:
        seconds = max(0, int(seconds))
        minutes, seconds = divmod(seconds, 60)
        hours, minutes = divmod(minutes, 60)
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"

    def on_stats(self, *arguments) -> None:
        stats = next((value for value in arguments if isinstance(value, str)), "")
        if not stats:
            return
        sample_match = self.SAMPLE_PATTERN.search(stats)
        if sample_match:
            self.sample = int(sample_match.group(1))
            self.sample_total = max(int(sample_match.group(2)), 1)
        remaining_match = self.REMAINING_PATTERN.search(stats)
        self.remaining = remaining_match.group(1).strip() if remaining_match else None
        stages = [
            part.strip()
            for part in stats.split("|")
            if part.strip()
            and not part.strip().startswith(("Mem:", "Remaining:", "Time:"))
        ]
        if stages:
            self.status = stages[-1]

    def line(self, tick: int) -> str:
        elapsed = self.duration(time.monotonic() - self.started_at)
        if self.sample is not None and self.sample_total:
            ratio = min(max(self.sample / self.sample_total, 0.0), 1.0)
            filled = min(round(ratio * self.BAR_WIDTH), self.BAR_WIDTH)
            bar = "#" * filled + "-" * (self.BAR_WIDTH - filled)
            remaining = f" | remaining {self.remaining}" if self.remaining else ""
            return (
                f"[Drop & View Cycles] [{bar}] {ratio * 100:5.1f}% "
                f"({self.sample}/{self.sample_total}){remaining} | elapsed {elapsed}"
            )
        travel = max(self.BAR_WIDTH - 4, 1)
        cycle = tick % (travel * 2)
        position = cycle if cycle <= travel else travel * 2 - cycle
        bar = " " * position + "====" + " " * (travel - position)
        return (
            f"[Drop & View Cycles] [{bar}] {self.status[:45]} | elapsed {elapsed}"
        )

    def animate(self) -> None:
        tick = 0
        while not self.stop_event.wait(0.5):
            sys.stdout.write(f"\r\033[2K{self.line(tick)}")
            sys.stdout.flush()
            tick += 1

    def start(self) -> None:
        if not self.enabled:
            return
        self.started_at = time.monotonic()
        bpy.app.handlers.render_stats.append(self.on_stats)
        self.thread = threading.Thread(target=self.animate, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        if not self.enabled:
            return
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=1.0)
        if self.on_stats in bpy.app.handlers.render_stats:
            bpy.app.handlers.render_stats.remove(self.on_stats)
        elapsed = self.duration(time.monotonic() - self.started_at)
        sys.stdout.write(
            f"\r\033[2K[Drop & View Cycles] "
            f"[{'#' * self.BAR_WIDTH}] render finished | elapsed {elapsed}\n"
        )
        sys.stdout.flush()


def bridge_arguments() -> argparse.Namespace:
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(description="Render a GLB or .dvrender with Cycles/Metal")
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--hdri", type=Path)
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--samples", type=int)
    parser.add_argument("--bounces", type=int)
    parser.add_argument("--transmission-bounces", type=int)
    return parser.parse_args(arguments)


def resource_index(manifest: dict, field: str) -> int | None:
    record = manifest.get(field)
    if record is None:
        return None
    index = record.get("resource") if isinstance(record, dict) else None
    if not isinstance(index, int) or isinstance(index, bool):
        raise ValueError(f"Invalid {field} resource")
    return index


def extract_resource(source, offset: int, length: int, target: Path) -> None:
    source.seek(offset)
    remaining = length
    with target.open("wb") as output:
        while remaining:
            block = source.read(min(remaining, 8 * 1024 * 1024))
            if not block:
                raise ValueError("Truncated render package resource")
            output.write(block)
            remaining -= len(block)


def decode_render_package(package: Path, temporary: Path) -> tuple[Path, Path | None, dict]:
    package_size = package.stat().st_size
    if package_size < 24 or package_size > MAX_PACKAGE_BYTES:
        raise ValueError("Invalid render package size")
    with package.open("rb") as source:
        header = source.read(12)
        if len(header) != 12 or header[:8] != b"DVRENDER":
            raise ValueError("Not a Drop & View render package")
        manifest_length = struct.unpack_from("<I", header, 8)[0]
        if manifest_length < 1 or manifest_length > MAX_MANIFEST_BYTES:
            raise ValueError("Invalid render package manifest size")
        manifest_bytes = source.read(manifest_length)
        if len(manifest_bytes) != manifest_length:
            raise ValueError("Truncated render package manifest")
        manifest = json.loads(manifest_bytes.decode("utf-8", errors="strict"))
        if not isinstance(manifest, dict):
            raise ValueError("Invalid render package manifest")
        lengths = manifest.get("lengths")
        if manifest.get("version") != 1 or not isinstance(lengths, list) or not lengths:
            raise ValueError("Unsupported render package")
        if "workbench" in manifest or "resolvedModel" in manifest:
            raise ValueError("Unsupported legacy render package; export it again")
        if len(lengths) > MAX_RESOURCES or any(
            not isinstance(length, int) or isinstance(length, bool) or length < 0
            for length in lengths
        ):
            raise ValueError("Invalid render package resources")
        resource_start = 12 + manifest_length
        offsets = []
        offset = resource_start
        for length in lengths:
            offsets.append(offset)
            offset += length
        if offset != package_size:
            raise ValueError("Render package length does not match its manifest")

        source.seek(offsets[0])
        if source.read(4) != b"glTF":
            raise ValueError("Render package model is not a GLB")
        model_path = temporary / "model.glb"
        extract_resource(source, offsets[0], lengths[0], model_path)

        hdri_path = None
        environment_index = resource_index(manifest, "environment")
        if environment_index is not None:
            if environment_index < 1 or environment_index >= len(lengths):
                raise ValueError("Invalid render package HDRI resource")
            hdri_path = temporary / "environment.hdr"
            extract_resource(
                source, offsets[environment_index], lengths[environment_index], hdri_path
            )

    return model_path, hdri_path, manifest


def reset_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (
        bpy.data.meshes,
        bpy.data.curves,
        bpy.data.materials,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def enable_cycles_metal(scene: bpy.types.Scene) -> list[str]:
    scene.render.engine = "CYCLES"
    scene.cycles.device = "GPU"
    preferences = bpy.context.preferences.addons["cycles"].preferences
    try:
        preferences.compute_device_type = "METAL"
        preferences.refresh_devices()
    except (AttributeError, TypeError):
        preferences.get_devices()

    enabled = []
    for device in preferences.devices:
        use_device = device.type == "METAL"
        device.use = use_device
        if use_device:
            enabled.append(device.name)
    if not enabled:
        scene.cycles.device = "CPU"
        print("[Drop & View Cycles] No Metal device found; using CPU.")
    else:
        print(f"[Drop & View Cycles] Metal devices: {', '.join(enabled)}")
    return enabled


def mesh_bounds() -> tuple[Vector, Vector]:
    minimum = Vector((math.inf, math.inf, math.inf))
    maximum = Vector((-math.inf, -math.inf, -math.inf))
    found = False
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or not obj.visible_get():
            continue
        found = True
        for corner in obj.bound_box:
            point = obj.matrix_world @ Vector(corner)
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            minimum.z = min(minimum.z, point.z)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
            maximum.z = max(maximum.z, point.z)
    if not found:
        raise RuntimeError("The GLB contains no visible mesh")
    return minimum, maximum


def center_imported_model(imported_roots: list[bpy.types.Object]) -> Vector:
    minimum, maximum = mesh_bounds()
    center = (minimum + maximum) * 0.5
    translation = Vector((-center.x, -center.y, -minimum.z))
    for obj in imported_roots:
        if obj.type != "CAMERA":
            obj.location += translation
    bpy.context.view_layer.update()
    return translation


def point_camera(camera: bpy.types.Object, target: Vector) -> None:
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()


def gltf_to_blender(vector: list[float]) -> Vector:
    return Vector((float(vector[0]), -float(vector[2]), float(vector[1])))


def drop_view_metadata(scene: bpy.types.Scene) -> dict:
    metadata = scene.get("dropView")
    if metadata is None:
        return {}
    return metadata.to_dict() if hasattr(metadata, "to_dict") else dict(metadata.items())


def create_framed_camera(scene: bpy.types.Scene, minimum: Vector, maximum: Vector) -> bpy.types.Object:
    center = (minimum + maximum) * 0.5
    radius = max((maximum - minimum).length * 0.5, 0.1)
    data = bpy.data.cameras.new("Drop View Camera")
    data.lens = 48
    data.sensor_width = 36
    data.clip_start = max(radius / 10_000, 0.001)
    data.clip_end = max(radius * 100, 1_000)
    camera = bpy.data.objects.new("Drop View Camera", data)
    scene.collection.objects.link(camera)
    vertical_fov = data.angle_y
    distance = radius / max(math.sin(vertical_fov * 0.5), 0.1) * 1.15
    camera.location = center + Vector((1.35, -1.55, 1.05)).normalized() * distance
    point_camera(camera, center)
    scene.camera = camera
    return camera


def choose_camera(
    scene: bpy.types.Scene, minimum: Vector, maximum: Vector, metadata: dict
) -> bpy.types.Object:
    initial_view = metadata.get("initialView", {})
    position = initial_view.get("position")
    cameras = [obj for obj in scene.objects if obj.type == "CAMERA"]
    if isinstance(position, list) and len(position) == 3 and cameras:
        expected = gltf_to_blender(position)
        camera = min(cameras, key=lambda candidate: (candidate.location - expected).length)
        scene.camera = camera
        print(f"[Drop & View Cycles] Using exported camera: {camera.name}")
        return camera
    return create_framed_camera(scene, minimum, maximum)


def camera_orientation(position: Vector, target: Vector, up: Vector):
    forward = (target - position).normalized()
    right = forward.cross(up).normalized()
    corrected_up = right.cross(forward).normalized()
    return Matrix((right, corrected_up, -forward)).transposed().to_quaternion()


def create_package_camera(
    scene: bpy.types.Scene, view_session: dict, minimum: Vector, maximum: Vector
) -> bpy.types.Object:
    saved = view_session.get("camera", {})
    position_values = saved.get("position")
    target_values = saved.get("target")
    up_values = saved.get("up")
    if not all(isinstance(value, list) and len(value) == 3 for value in (
        position_values, target_values, up_values
    )):
        raise ValueError("Render package camera is invalid")
    position = gltf_to_blender(position_values)
    target = gltf_to_blender(target_values)
    up = gltf_to_blender(up_values).normalized()
    if (target - position).length < 1e-6 or abs((target - position).normalized().dot(up)) > 0.999:
        raise ValueError("Render package camera orientation is invalid")

    data = bpy.data.cameras.new("Drop View Package Camera")
    data.clip_start = max((maximum - minimum).length / 10_000, 0.001)
    data.clip_end = max((maximum - minimum).length * 100, 1_000)
    projection = saved.get("projection")
    if projection == "perspective":
        fov = float(saved.get("fov"))
        if not 0 < fov < 180:
            raise ValueError("Render package camera FOV is invalid")
        data.type = "PERSP"
        data.sensor_fit = "VERTICAL"
        data.lens = data.sensor_height / (2 * math.tan(math.radians(fov) * 0.5))
    elif projection in {"axon", "ortho"}:
        data.type = "ORTHO"
        zoom = float(saved.get("zoom", 1))
        maximum_size = max(*(maximum - minimum), 0.1)
        data.ortho_scale = maximum_size * 1.44 / max(zoom, 1e-6)
    else:
        raise ValueError("Unsupported render package camera projection")

    camera = bpy.data.objects.new("Drop View Package Camera", data)
    scene.collection.objects.link(camera)
    camera.location = position
    camera.rotation_mode = "QUATERNION"
    camera.rotation_quaternion = camera_orientation(position, target, up)
    scene.camera = camera
    print(f"[Drop & View Cycles] Using package camera ({projection})")
    return camera


def apply_group_visibility(imported_roots: list[bpy.types.Object], view_session: dict) -> None:
    groups = [obj for obj in imported_roots if obj.type != "CAMERA"]
    for record in view_session.get("groups", []):
        try:
            index, label = json.loads(record["sessionKey"])
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            continue
        if not isinstance(index, int) or index < 0 or index >= len(groups):
            continue
        group = groups[index]
        group.hide_render = not bool(record.get("visible", True))
        group.hide_viewport = group.hide_render
        if label and group.name != label:
            print(
                f"[Drop & View Cycles] Group {index} label differs: "
                f"package={label!r}, Blender={group.name!r}"
            )


def create_sun(
    scene: bpy.types.Scene,
    center: Vector,
    radius: float,
    metadata: dict,
    view_session: dict | None = None,
) -> None:
    data = bpy.data.lights.new("Drop View Sun", type="SUN")
    data.energy = 2.5
    data.angle = math.radians(3.0)
    sun = bpy.data.objects.new("Drop View Sun", data)
    scene.collection.objects.link(sun)
    settings = view_session.get("settings", {}) if view_session else {}
    if settings.get("sunAngle") is not None and settings.get("sunHeight") is not None:
        azimuth = math.radians(float(settings["sunAngle"]))
        elevation = math.radians(float(settings["sunHeight"]))
        horizontal = math.cos(elevation)
        direction_to_sun = gltf_to_blender([
            math.cos(azimuth) * horizontal,
            math.sin(elevation),
            math.sin(azimuth) * horizontal,
        ]).normalized()
    else:
        saved_direction = metadata.get("sun", {}).get("directionToSun")
        direction_to_sun = (
            gltf_to_blender(saved_direction).normalized()
            if isinstance(saved_direction, list) and len(saved_direction) == 3
            else Vector((0.65, -0.55, 0.8)).normalized()
        )
    sun.location = center + direction_to_sun * max(radius * 3, 10)
    sun.rotation_euler = (-direction_to_sun).to_track_quat("-Z", "Y").to_euler()


def hdri_sun_direction(image: bpy.types.Image) -> Vector | None:
    width, height = image.size
    channels = image.channels
    if width < 1 or height < 1 or channels < 3:
        return None
    try:
        import numpy

        pixels = numpy.empty(width * height * channels, dtype=numpy.float32)
        image.pixels.foreach_get(pixels)
        colors = pixels.reshape((-1, channels))
        luminance = (
            colors[:, 0] * 0.2126 + colors[:, 1] * 0.7152 + colors[:, 2] * 0.0722
        )
        brightest = int(numpy.argmax(luminance))
    except (ImportError, ValueError):
        return None
    x = brightest % width
    # Blender exposes image pixels bottom-up; the web HDR loader uses top-down.
    y = height - 1 - brightest // width
    azimuth = ((x + 0.5) / width - 0.5) * math.tau
    elevation = math.pi * 0.5 - ((y + 0.5) / height) * math.pi
    horizontal = math.cos(elevation)
    return gltf_to_blender([
        math.cos(azimuth) * horizontal,
        math.sin(elevation),
        math.sin(azimuth) * horizontal,
    ]).normalized()


def saved_sun_direction(view_session: dict | None) -> Vector | None:
    settings = view_session.get("settings", {}) if view_session else {}
    if settings.get("sunAngle") is None or settings.get("sunHeight") is None:
        return None
    azimuth = math.radians(float(settings["sunAngle"]))
    elevation = math.radians(float(settings["sunHeight"]))
    horizontal = math.cos(elevation)
    return gltf_to_blender([
        math.cos(azimuth) * horizontal,
        math.sin(elevation),
        math.sin(azimuth) * horizontal,
    ]).normalized()


def configure_world(
    scene: bpy.types.Scene, hdri: Path | None, view_session: dict | None = None
) -> None:
    world = bpy.data.worlds.new("Drop View World")
    world.use_nodes = True
    scene.world = world
    nodes = world.node_tree.nodes
    links = world.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputWorld")
    background = nodes.new("ShaderNodeBackground")
    background.inputs["Strength"].default_value = 0.8
    links.new(background.outputs["Background"], output.inputs["Surface"])
    if hdri and hdri.is_file():
        environment = nodes.new("ShaderNodeTexEnvironment")
        environment.image = bpy.data.images.load(str(hdri), check_existing=True)
        coordinates = nodes.new("ShaderNodeTexCoord")
        mapping = nodes.new("ShaderNodeMapping")
        source_sun = hdri_sun_direction(environment.image)
        target_sun = saved_sun_direction(view_session)
        if source_sun is not None and target_sun is not None:
            source_to_target = source_sun.rotation_difference(target_sun)
            mapping.inputs["Rotation"].default_value = source_to_target.inverted().to_euler()
            print("[Drop & View Cycles] Aligned HDRI sun to saved sun controls")
        links.new(coordinates.outputs["Generated"], mapping.inputs["Vector"])
        links.new(mapping.outputs["Vector"], environment.inputs["Vector"])
        links.new(environment.outputs["Color"], background.inputs["Color"])
        print(f"[Drop & View Cycles] HDRI: {hdri}")
    else:
        background.inputs["Color"].default_value = (0.12, 0.15, 0.2, 1.0)


def configure_render(scene: bpy.types.Scene, args: argparse.Namespace, output: Path) -> None:
    scene.render.resolution_x = args.width
    scene.render.resolution_y = args.height
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.film_transparent = False
    scene.render.filepath = str(output)
    scene.cycles.samples = args.samples
    # Temporary RAW benchmark mode: evaluate every requested sample on every
    # pixel and keep the unfiltered Cycles result for timing/quality comparison.
    scene.cycles.use_denoising = False
    scene.cycles.denoiser = "OPENIMAGEDENOISE"
    scene.cycles.max_bounces = args.bounces
    scene.cycles.transmission_bounces = args.transmission_bounces
    scene.cycles.use_adaptive_sampling = False
    if scene.cycles.use_denoising or scene.cycles.use_adaptive_sampling:
        raise RuntimeError("RAW benchmark settings were not accepted by Blender")
    print(
        "[Drop & View Cycles] VERIFIED: adaptive sampling OFF, "
        f"denoise OFF, fixed samples {scene.cycles.samples}"
    )
    scene.render.use_file_extension = True
    try:
        scene.view_settings.look = "AgX - Medium High Contrast"
    except TypeError:
        pass


def main() -> None:
    args = bridge_arguments()
    input_path = args.input.expanduser().resolve()
    if input_path.suffix.lower() not in {".glb", ".dvrender"} or not input_path.is_file():
        raise ValueError(f"Expected an existing GLB or .dvrender file: {input_path}")

    with tempfile.TemporaryDirectory(prefix="drop-view-cycles-") as temporary_name:
        temporary = Path(temporary_name)
        manifest = None
        packaged_hdri = None
        if input_path.suffix.lower() == ".dvrender":
            model_path, packaged_hdri, manifest = decode_render_package(input_path, temporary)
        else:
            model_path = input_path

        render_size = manifest.get("renderSize") if manifest else None
        render_job = manifest.get("renderJob") if manifest else None
        args.width = args.width or (render_size or {}).get("width") or 1280
        args.height = args.height or (render_size or {}).get("height") or 720
        args.samples = args.samples or (render_job or {}).get("samples") or 64
        args.bounces = args.bounces or (render_job or {}).get("bounces") or 6
        args.transmission_bounces = (
            args.transmission_bounces
            or (render_job or {}).get("transmissiveBounces")
            or 10
        )
        if args.width < 8 or args.height < 8 or args.samples < 1:
            raise ValueError("Width, height and samples must be positive")

        script_root = Path(__file__).resolve().parents[2]
        default_hdri = script_root / "assets" / "hdri" / "backdrop.hdr"
        hdri = (
            args.hdri.expanduser().resolve()
            if args.hdri
            else packaged_hdri or default_hdri
        )
        output = (
            args.output or input_path.with_name(f"{input_path.stem}-cycles.png")
        ).expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)

        reset_scene()
        scene = bpy.context.scene
        enable_cycles_metal(scene)
        print(f"[Drop & View Cycles] Importing: {model_path}")
        bpy.ops.import_scene.gltf(
            filepath=str(model_path),
            import_pack_images=True,
            import_shading="NORMALS",
            import_scene_extras=True,
        )
        imported_roots = [obj for obj in scene.objects if obj.parent is None]
        metadata = drop_view_metadata(scene)
        view_session = manifest.get("viewSession") if manifest else None
        if view_session:
            center_imported_model(imported_roots)
            apply_group_visibility(imported_roots, view_session)
        minimum, maximum = mesh_bounds()
        center = (minimum + maximum) * 0.5
        radius = max((maximum - minimum).length * 0.5, 0.1)
        if view_session:
            create_package_camera(scene, view_session, minimum, maximum)
        else:
            choose_camera(scene, minimum, maximum, metadata)
        # A packaged HDRI carries the final environment illumination and its
        # brightest point is rotated to the saved sun controls below.
        if not packaged_hdri:
            create_sun(scene, center, radius, metadata, view_session)
        configure_world(scene, hdri, view_session if packaged_hdri else None)
        configure_render(scene, args, output)

        print(
            f"[Drop & View Cycles] Rendering {args.width}x{args.height}, "
            f"{args.samples} RAW fixed samples, denoise OFF -> {output}"
        )
        print(
            "[Drop & View Cycles] The PNG appears only after rendering finishes; "
            "keep this window open and wait for READY."
        )
        progress = RenderProgress()
        progress.start()
        try:
            bpy.ops.render.render(write_still=True)
        finally:
            progress.stop()
        print(f"[Drop & View Cycles] READY: {output}")


if __name__ == "__main__":
    main()
