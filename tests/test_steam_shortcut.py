"""Tests for scripts/steam_shortcut.py (run by tests/run.sh).

Everything happens under a temporary fake HOME; the real Steam
installation is never touched.
"""

import importlib.util
import io
import os
import struct
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("steam_shortcut", os.path.join(HERE, "..", "scripts", "steam_shortcut.py"))
ss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ss)


def raw_vdf_with_uint64():
    """A shortcuts.vdf as Steam might write it, including a 0x07 field."""
    entry = (b"\x02appid\x00" + struct.pack("<i", -123456)
             + b"\x01AppName\x00Other Game\x00"
             + b"\x07LastPlayTime64\x00" + struct.pack("<Q", 2 ** 40 + 5)
             + b"\x00tags\x00\x010\x00fav\x00\x08"
             + b"\x08")
    return b"\x00shortcuts\x00" + b"\x000\x00" + entry + b"\x08" + b"\x08"


class VdfTests(unittest.TestCase):
    def test_round_trip_is_byte_identical(self):
        raw = raw_vdf_with_uint64()
        data, _ = ss.vdf_load(raw)
        self.assertIsInstance(data["shortcuts"]["0"]["LastPlayTime64"], ss.UInt64)
        self.assertEqual(ss.vdf_dump(data), raw)

    def test_unknown_type_is_rejected(self):
        with self.assertRaises(ValueError):
            ss.vdf_load(b"\x00shortcuts\x00\x05x\x00\x08\x08")


class ShortcutFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        self.config = os.path.join(self.home, ".local/share/Steam/userdata/12345/config")
        os.makedirs(self.config)
        self.vdf = os.path.join(self.config, "shortcuts.vdf")
        with open(self.vdf, "wb") as f:
            f.write(raw_vdf_with_uint64())
        self.patches = [
            mock.patch.dict(os.environ, {"HOME": self.home}),
            mock.patch.object(ss, "steam_running", lambda: False),
            mock.patch("sys.stdout", new_callable=io.StringIO),  # helper's progress prints
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def load(self):
        with open(self.vdf, "rb") as f:
            return ss.vdf_load(f.read())[0]["shortcuts"]

    def test_add_is_idempotent_and_preserves_other_shortcuts(self):
        ss.cmd_add(None)
        ss.cmd_add(None)
        shortcuts = self.load()
        names = [s["AppName"] for s in shortcuts.values()]
        self.assertEqual(names, ["Other Game", ss.APP_NAME])
        self.assertEqual(shortcuts["0"]["LastPlayTime64"], 2 ** 40 + 5)
        grid = os.listdir(os.path.join(self.config, "grid"))
        self.assertEqual(len(grid), len(ss.ARTWORK))
        self.assertTrue(os.path.exists(self.vdf + ".bak"))

    def test_remove(self):
        ss.cmd_add(None)
        ss.cmd_remove(None)
        shortcuts = self.load()
        self.assertEqual([s["AppName"] for s in shortcuts.values()], ["Other Game"])
        self.assertEqual(os.listdir(os.path.join(self.config, "grid")), [])

    def pin(self, launch):
        ss.cmd_add(None)
        path, data = ss.load_shortcuts(self.config)
        _, sc = ss.find_ours(data)
        sc["LaunchOptions"] = launch
        ss.save_shortcuts(path, data)

    def ours(self):
        return [s for s in self.load().values() if s["AppName"] == ss.APP_NAME][0]

    def test_repair_unpins_branch(self):
        self.pin("run --branch=master --arch=x86_64 --command=deckvideoplayer " + ss.FLATPAK_ID)
        ss.cmd_repair(None)
        self.assertEqual(self.ours()["LaunchOptions"],
                         "run --arch=x86_64 --command=deckvideoplayer " + ss.FLATPAK_ID)
        self.assertEqual(self.ours()["AppName"], ss.APP_NAME)
        self.assertEqual(self.load()["0"]["LastPlayTime64"], 2 ** 40 + 5)

    def test_repair_waits_for_steam(self):
        self.pin("run --branch master " + ss.FLATPAK_ID)
        with mock.patch.object(ss, "steam_running", lambda: True):
            with self.assertRaises(SystemExit) as cm:
                ss.cmd_repair(None)
        self.assertEqual(cm.exception.code, 3)
        self.assertIn("--branch master", self.ours()["LaunchOptions"])

    def test_repair_current_branch_is_fine_while_steam_runs(self):
        self.pin("run --branch=stable " + ss.FLATPAK_ID)
        with mock.patch.object(ss, "steam_running", lambda: True):
            ss.cmd_repair(None)   # no exit: it still works

    def test_unpin_keeps_quotes(self):
        sc = {"Exe": '"/usr/bin/flatpak run --branch=master"', "LaunchOptions": ""}
        self.assertEqual(ss.pinned_branch(sc), "master")
        ss.unpin_branch(sc)
        self.assertEqual(sc["Exe"], '"/usr/bin/flatpak run"')

    def test_add_unpins_existing(self):
        self.pin("run --branch=master " + ss.FLATPAK_ID)
        ss.cmd_add(None)
        self.assertEqual(self.ours()["LaunchOptions"], "run " + ss.FLATPAK_ID)

    def test_failed_save_leaves_file_intact(self):
        before = open(self.vdf, "rb").read()
        with mock.patch.object(ss, "vdf_dump", side_effect=TypeError("boom")):
            with self.assertRaises(TypeError):
                ss.cmd_add(None)
        self.assertEqual(open(self.vdf, "rb").read(), before)


if __name__ == "__main__":
    unittest.main()
