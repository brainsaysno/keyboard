from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENDER_JS = ROOT / "macos/dashboard/render.js"
WIDTH, HEIGHT, STRIDE = 68, 160, 9

# Covers every unit of render.js ageLbl() on both sides of its boundaries and all ten digits.
STALE_CASES = ["never", 0, 7, 38, 59, 60, 95, 1439, 1440, 1500, 10079, 10080, 20000, 2**32 - 1]


def reference_frames(states):
    node = shutil.which("node")
    if node is None:
        raise AssertionError("node is required to run render.js")
    script = (f"require({json.dumps(str(RENDER_JS))});"
              f"const states = {json.dumps(states)};"
              "process.stdout.write(JSON.stringify(states.map(s => CorneDashboard.render(s, 0))));")
    output = subprocess.run([node, "-e", script], check=True, capture_output=True, text=True).stdout
    return [bytes(frame) for frame in json.loads(output)]


def first_difference(actual, expected):
    for y in range(HEIGHT):
        for x in range(WIDTH):
            index, bit = y * STRIDE + (x >> 3), 0x80 >> (x & 7)
            if (actual[index] ^ expected[index]) & bit:
                return x, y
    return None


class DashboardFirmwareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("cc")
        if compiler is None:
            raise AssertionError("A host C compiler is required")
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        cls.harness = Path(directory.name) / "dashboard-test"
        subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-I", str(ROOT / "src"),
                        str(ROOT / "src/dashboard_stale.c"), str(ROOT / "tests/dashboard_test.c"),
                        "-o", str(cls.harness)], check=True)

    def firmware_frame(self, case):
        return subprocess.run([str(self.harness), str(case)], check=True, capture_output=True).stdout

    def test_stale_screen_matches_render_js(self):
        states = [{"stale": {"never": True} if case == "never" else {"mins": case}} for case in STALE_CASES]
        for case, expected in zip(STALE_CASES, reference_frames(states)):
            with self.subTest(case=case):
                actual = self.firmware_frame(case)
                self.assertEqual(len(actual), STRIDE * HEIGHT)
                self.assertEqual(len(expected), STRIDE * HEIGHT)
                self.assertIsNone(first_difference(actual, expected), "first differing pixel (x, y)")
                self.assertEqual(actual, expected)

    def test_message_validation(self):
        subprocess.run([str(self.harness), "messages"], check=True)


if __name__ == "__main__":
    unittest.main()
