import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class KeymapTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "config/corne.keymap").read_text()
        clean = re.sub(r"/\*.*?\*/|//[^\n]*", "", self.source, flags=re.S)
        self.layers = {}
        for name, body in re.findall(r"(\w+_layer)\s*\{(.*?)\};", clean, re.S):
            bindings = re.search(r"bindings\s*=\s*<(.*?)>;", body, re.S).group(1)
            self.layers[name] = [tuple(entry.split()) for entry in re.findall(r"&([^&]+)", bindings)]

    def test_layer_sizes_and_binding_arguments(self):
        self.assertEqual(list(self.layers), ["default_layer", "lower_layer", "raise_layer", "adjust_layer"])
        for name, entries in self.layers.items():
            self.assertEqual(len(entries), 42, name)
            for entry in entries:
                arity = {"kp": 1, "mt": 2, "mo": 1, "trans": 0, "none": 0,
                         "mmv": 1, "mkp": 1, "mouse_down_scroll": 0, "mouse_up_scroll": 0,
                         "bt": 2 if entry[1:2] == ("BT_SEL",) else 1}[entry[0]]
                self.assertEqual(len(entry), arity + 1, (name, entry))

    def test_clipboard_and_vertical_mouse_positions(self):
        lower = self.layers["lower_layer"]
        self.assertEqual(lower[27], ("kp", "CLIPBOARD_HISTORY"))
        self.assertRegex(self.source, r"#define\s+CLIPBOARD_HISTORY\s+F18\b")
        self.assertEqual(lower[30:34], [("mmv", "MOVE_LEFT"), ("mouse_down_scroll",),
                                      ("mouse_up_scroll",), ("mmv", "MOVE_RIGHT")])
        self.assertEqual(lower[18:22], [("kp", "LEFT"), ("kp", "DOWN"), ("kp", "UP"), ("kp", "RIGHT")])
        self.assertEqual(lower[24], ("kp", "LSHFT"))
        for direction in ("DOWN", "UP"):
            self.assertIn(f"bindings = <&mmv MOVE_{direction}>, <&msc SCRL_{direction}>;", self.source)

    def test_existing_audio_and_bluetooth_bindings(self):
        self.assertEqual(self.layers["raise_layer"][25:30], [
            ("kp", "C_MUTE"), ("kp", "AIRPODS_ANC"), ("kp", "AIRPODS_TRANSPARENCY"),
            ("kp", "C_BRI_DN"), ("kp", "C_BRI_UP")])
        for layer in ("lower_layer", "adjust_layer"):
            self.assertEqual(self.layers[layer][13:18], [("bt", "BT_SEL", str(i)) for i in range(5)])
        self.assertEqual(self.layers["adjust_layer"][25:28], [("bt", "BT_PRV"), ("bt", "BT_CLR"), ("bt", "BT_NXT")])
        self.assertIn("if-layers = <1 2>;", self.source)
        self.assertIn("then-layer = <3>;", self.source)

    def test_karabiner_rule(self):
        document = json.loads((ROOT / "macos/clipboard-history.json").read_text())
        rule = document["rules"][0]["manipulators"][0]
        self.assertEqual(rule["from"], {"key_code": "f18"})
        self.assertFalse(rule["to"][0]["repeat"])
        self.assertEqual(rule["to"][0]["shell_command"],
                         "/usr/bin/open 'raycast://extensions/raycast/clipboard-history/clipboard-history'")

    def test_shift_scroll_c_behavior(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "A host C compiler is required")
        # Compile the actual driver, including both device-definition macro expansions.
        # Only Zephyr/ZMK interfaces are stubbed; this is not a firmware integration test.
        shim = r'''
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#define MOD_LSFT 0x02
#define MOD_RSFT 0x20
#define MOD_LCTL 0x01
#define HID_USAGE_KEY 0x07
#define IS_ENABLED(x) 0
struct zmk_behavior_binding { const char *behavior_dev; uint32_t param1, param2; };
struct zmk_behavior_binding_event { uint32_t position; int64_t timestamp; };
struct behavior_driver_api {
    int (*binding_pressed)(struct zmk_behavior_binding *, struct zmk_behavior_binding_event);
    int (*binding_released)(struct zmk_behavior_binding *, struct zmk_behavior_binding_event);
};
struct device { const void *config; void *data; const struct behavior_driver_api *api; };
const struct device *zmk_behavior_get_binding(const char *);
unsigned char zmk_hid_get_explicit_mods(void);
int zmk_hid_masked_modifiers_set(unsigned char);
int zmk_hid_masked_modifiers_clear(void);
int zmk_endpoints_send_report(int);
int zmk_behavior_invoke_binding(struct zmk_behavior_binding *, struct zmk_behavior_binding_event, bool);
#define DEVICE_DT_NAME(node) ((node) == 0 ? "move" : "scroll")
#define DT_INST_PHANDLE_BY_IDX(n, prop, idx) idx
#define DT_INST_PHA_BY_IDX(n, prop, idx, cell) n
#define DT_INST_PROP_LEN(n, prop) 2
#define BUILD_ASSERT(test, message) _Static_assert(test, message)
#define BEHAVIOR_DT_INST_DEFINE(n, init, pm, data_ptr, config_ptr, level, priority, api_ptr) \
    static const struct device device_##n = {config_ptr, data_ptr, api_ptr}
#define DT_INST_FOREACH_STATUS_OKAY(fn) fn(0) fn(1)
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "shim.h").write_text(shim)
            for header in ["zephyr/device.h", "drivers/behavior.h", "dt-bindings/zmk/modifiers.h",
                           "dt-bindings/zmk/hid_usage_pages.h", "zmk/behavior.h", "zmk/endpoints.h", "zmk/hid.h"]:
                path = root / header
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('#include "shim.h"\n')
            executable = root / "shift-scroll-test"
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address,undefined", "-I", directory,
                            str(ROOT / "tests/shift_scroll_test.c"), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main()
