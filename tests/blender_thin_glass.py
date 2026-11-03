"""Run with Blender --background --factory-startup --python-exit-code 1 --python this_file."""

import importlib
import json
from pathlib import Path
import runpy
import struct
import tempfile
from types import SimpleNamespace

import bpy


adapter = runpy.run_path(str(
    Path(__file__).resolve().parents[1] / "DropViewRender/Resources/render_glb.py"
))


def glass(name, marker=None, thickness=0, transmission=0.9):
    material = {
        "name": name,
        "pbrMetallicRoughness": {
            "baseColorFactor": [0.7, 0.8, 0.9, 1],
            "metallicFactor": 0,
            "roughnessFactor": 0.12,
        },
        "extensions": {
            "KHR_materials_transmission": {"transmissionFactor": transmission},
            "KHR_materials_volume": {"thicknessFactor": thickness},
            "KHR_materials_ior": {"ior": 1.33},
        },
    }
    if marker is not None:
        material["extras"] = {"archicad": {"clearGlassOverride": marker}}
    return material


materials = [
    glass("marked-thin", True),
    glass("unmarked-thin"),
    glass("explicitly-not-clear", False),
    glass("marked-solid", True, thickness=0.01),
    glass("marked-no-transmission", True, transmission=0),
    glass("wrong-marker-type", "true"),
]
alpha = glass("alpha-only", True, transmission=0)
alpha["alphaMode"] = "BLEND"
alpha["pbrMetallicRoughness"]["baseColorFactor"][3] = 0.3
materials.append(alpha)
binary = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 1, 0)
document = {
    "asset": {"version": "2.0"},
    "extensionsUsed": ["KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_ior"],
    "buffers": [{"byteLength": len(binary)}],
    "bufferViews": [{"buffer": 0, "byteLength": len(binary)}],
    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3,
                   "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]}],
    "materials": materials,
    "meshes": [{"primitives": [
        {"attributes": {"POSITION": 0}, "material": index}
        for index in range(len(materials))
    ]}],
    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0,
}
payload = json.dumps(document).encode()
payload += b" " * (-len(payload) % 4)
glb = (
    struct.pack("<4sII", b"glTF", 2, 28 + len(payload) + len(binary))
    + struct.pack("<I4s", len(payload), b"JSON") + payload
    + struct.pack("<I4s", len(binary), b"BIN\0") + binary
)
module = importlib.import_module("io_scene_gltf2.blender.imp.material")
original_hook = module.import_user_extensions
with tempfile.TemporaryDirectory(prefix="drop-view-thin-glass-test-") as temporary:
    path = Path(temporary) / "materials.glb"
    path.write_bytes(glb)
    adapter["import_model"](path)
    assert path.read_bytes() == glb
assert module.import_user_extensions is original_hook
for source in materials:
    material = bpy.data.materials[source["name"]]
    shader = next(n for n in material.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    assert bool(shader.inputs["Thin Wall"].default_value) == (source["name"] == "marked-thin"), source["name"]
    shadow_nodes = [n for n in material.node_tree.nodes if n.type == "BSDF_TRANSPARENT"
                    and n.label == "Clear glass shadow tint"]
    assert bool(shadow_nodes) == (source["name"] == "marked-thin"), source["name"]
    if shadow_nodes:
        assert all(abs(a - b) < 1e-5 for a, b in zip(
            shadow_nodes[0].inputs["Color"].default_value, (0.7, 0.8, 0.9, 1)))
        weight = next(n for n in material.node_tree.nodes if n.label == "Shadow ray × glass transmission")
        assert abs(weight.inputs[1].default_value - 1.0) < 1e-5
    calibrated = source["name"] == "marked-thin"
    assert abs(shader.inputs["Roughness"].default_value - (0.01 if calibrated else 0.12)) < 1e-5
    assert abs(shader.inputs["IOR"].default_value - (1.51 if calibrated else 1.33)) < 1e-5
    expected_transmission = 1.0 if calibrated else source["extensions"]["KHR_materials_transmission"]["transmissionFactor"]
    assert abs(shader.inputs["Transmission Weight"].default_value - expected_transmission) < 1e-5
assert all(obj.visible_shadow for obj in bpy.context.scene.objects)

# Exact calibration must also work for linked inputs without clearing the
# imported color/normal graph or widening the shadow-only ray policy.
material = bpy.data.materials.new("linked-clear-glass")
shader = material.node_tree.nodes.get("Principled BSDF")
for name in ("IOR", "Roughness", "Transmission Weight"):
    value = material.node_tree.nodes.new("ShaderNodeValue")
    value.outputs[0].default_value = 0.5
    material.node_tree.links.new(value.outputs[0], shader.inputs[name])
color = material.node_tree.nodes.new("ShaderNodeRGB")
material.node_tree.links.new(color.outputs[0], shader.inputs["Base Color"])
normal = material.node_tree.nodes.new("ShaderNodeNormalMap")
material.node_tree.links.new(normal.outputs["Normal"], shader.inputs["Normal"])
source = SimpleNamespace(extras=materials[0]["extras"], extensions=materials[0]["extensions"])
assert adapter["configure_thin_glass"](source, material)
for name, expected in (("IOR", 1.51), ("Roughness", 0.01), ("Transmission Weight", 1.0)):
    assert not shader.inputs[name].is_linked
    assert abs(shader.inputs[name].default_value - expected) < 1e-5
assert shader.inputs["Base Color"].links[0].from_node == color
assert shader.inputs["Normal"].links[0].from_node == normal
transparent = next(n for n in material.node_tree.nodes if n.type == "BSDF_TRANSPARENT")
assert transparent.inputs["Color"].links[0].from_node == color
weight = next(n for n in material.node_tree.nodes if n.label == "Shadow ray × glass transmission")
assert weight.inputs[0].links[0].from_socket.name == "Is Shadow Ray"
print("PASS: explicit clear-glass policy, solid/alpha exclusions, optical values, hook restoration")
