"""GPU selection policy without requiring GPU hardware; real Blender smoke is separate."""
import ast
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

source = ast.parse((Path(__file__).resolve().parents[1] / "DropViewRender/Resources/render_glb.py").read_text())
module = ast.Module(body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)] +
                    [node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == "enable_cycles_device"], type_ignores=[])

class Preferences:
    def __init__(self, available):
        self.available = available
        self.devices = []
    @property
    def compute_device_type(self):
        return self.backend
    @compute_device_type.setter
    def compute_device_type(self, value):
        if value not in self.available:
            raise TypeError("unsupported backend")
        self.backend = value
    def refresh_devices(self):
        self.devices = [SimpleNamespace(type="CPU", name="CPU", use=True)]
        if self.available[self.backend]:
            self.devices.append(SimpleNamespace(type=self.backend, name="Test GPU", use=False))

class DeviceTests(unittest.TestCase):
    def select(self, platform, available, request="AUTO"):
        prefs = Preferences(available)
        scene = SimpleNamespace(render=SimpleNamespace(), cycles=SimpleNamespace())
        namespace = {"sys": SimpleNamespace(platform=platform), "bpy": SimpleNamespace(context=SimpleNamespace(
            preferences=SimpleNamespace(addons={"cycles": SimpleNamespace(preferences=prefs)})))}
        exec(compile(ast.fix_missing_locations(module), "device-policy", "exec"), namespace)
        result = namespace["enable_cycles_device"](scene, request)
        return scene, prefs, result
    def test_macos_keeps_metal(self):
        scene, prefs, names = self.select("darwin", {"METAL": True, "OPTIX": True})
        self.assertEqual(prefs.backend, "METAL")
        self.assertEqual(scene.cycles.device, "GPU")
        self.assertEqual(names, ["Test GPU"])
        self.assertFalse(prefs.devices[0].use)
    def test_windows_vendor_backends_and_cpu_fallback(self):
        for backend in ["OPTIX", "CUDA", "HIP", "ONEAPI"]:
            scene, prefs, _ = self.select("win32", {backend: True})
            self.assertEqual(prefs.backend, backend)
            self.assertEqual(scene.cycles.device, "GPU")
        scene, _, names = self.select("win32", {"OPTIX": False})
        self.assertEqual(scene.cycles.device, "CPU")
        self.assertEqual(names, [])
    def test_explicit_unavailable_backend_fails(self):
        with self.assertRaises(RuntimeError):
            self.select("win32", {}, "OPTIX")
    def test_explicit_cpu(self):
        scene, _, names = self.select("win32", {"OPTIX": True}, "CPU")
        self.assertEqual(scene.cycles.device, "CPU")
        self.assertEqual(names, [])

if __name__ == "__main__":
    unittest.main()
