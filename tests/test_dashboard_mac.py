from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "macos/dashboard"

# Renders each state with render.js and lists every key render.js reads that the state lacks,
# so a misnamed field fails here instead of drawing "UNDEFINED" on the keyboard.
RENDER_STATES = r"""
const states = JSON.parse(require('fs').readFileSync(0, 'utf8'));
require(process.argv[1]);
console.log(JSON.stringify(states.map(state => {
  const missing = [];
  const watch = (object, path) => new Proxy(object, {
    get(target, key) {
      const value = target[key];
      if (typeof key !== 'string') return value;
      if (!(key in target)) missing.push(path + key);
      return value !== null && typeof value === 'object' ? watch(value, path + key + '.') : value;
    },
  });
  const frame = globalThis.CorneDashboard.render(watch(state, ''));
  return {length: frame.length, bytes: frame.every(b => Number.isInteger(b) && b >= 0 && b <= 255), missing};
})));
"""


class DashboardMacTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("swiftc")
        if compiler is None:
            raise AssertionError("swiftc is required")
        # Only the pure logic: no CoreBluetooth, EventKit, or Core Audio in this build.
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "dashboard-mac-test"
            subprocess.run([compiler, "-warnings-as-errors", str(DASHBOARD / "Logic.swift"),
                            str(ROOT / "tests/dashboard_mac_test.swift"), "-o", str(executable)], check=True)
            cls.result = subprocess.run([str(executable)], capture_output=True, text=True)

    def test_swift_logic(self):
        self.assertEqual(self.result.returncode, 0, self.result.stdout + self.result.stderr)

    def test_states_render_with_render_js(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "node is required")
        states = [json.loads(line.removeprefix("STATE "))
                  for line in self.result.stdout.splitlines() if line.startswith("STATE ")]
        self.assertEqual([s["meet"]["mode"] for s in states],
                         ["none", "next", "next", "alert", "onair", "onair", "onair"])
        rendered = subprocess.run([node, "-e", RENDER_STATES, str(DASHBOARD / "render.js")],
                                  input=json.dumps(states), capture_output=True, text=True)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        for state, frame in zip(states, json.loads(rendered.stdout)):
            with self.subTest(meet=state["meet"]):
                self.assertEqual(frame["length"], 1440)
                self.assertTrue(frame["bytes"])
                # Only the firmware's "no data" screen sets "stale".
                self.assertEqual([key for key in frame["missing"] if key != "stale"], [])


if __name__ == "__main__":
    unittest.main()
