"""Tests for scripts/update-yt-dlp.py (the manifest rewrite only; no network)."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("update_yt_dlp", os.path.join(HERE, "..", "scripts", "update-yt-dlp.py"))
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)

OLD_ZIP = "a" * 64
OLD_LIC = "b" * 64
MANIFEST = f"""modules:
  - name: other
    sources:
      - type: file
        url: https://example.org/yt-dlp/2020.01.01/yt-dlp
        sha256: {"c" * 64}

  - name: yt-dlp
    buildsystem: simple
    sources:
      - type: file
        url: {up.RELEASES}/2026.10.26/yt-dlp
        sha256: {OLD_ZIP}
      - type: file
        url: {up.RAW}/2026.10.26/LICENSE
        sha256: {OLD_LIC}

  - name: inter-font
"""


class UpdateYtDlp(unittest.TestCase):
    def test_current_tag(self):
        self.assertEqual(up.current_tag(MANIFEST), "2026.10.26")
        # Only the yt-dlp module counts, not a look-alike source before it.
        other = MANIFEST.replace("https://example.org/yt-dlp/2020.01.01/yt-dlp", f"{up.RELEASES}/2020.01.01/yt-dlp")
        self.assertEqual(up.current_tag(other), "2026.10.26")
        self.assertIsNone(up.current_tag("modules:\n  - name: mpv\n"))

    def test_rewrite_only_the_module(self):
        new = up.rewrite_manifest(MANIFEST, "2026.11.30", "1" * 64, "2" * 64)
        self.assertIn(f"{up.RELEASES}/2026.11.30/yt-dlp\n        sha256: {'1' * 64}", new)
        self.assertIn(f"{up.RAW}/2026.11.30/LICENSE\n        sha256: {'2' * 64}", new)
        self.assertNotIn(OLD_ZIP, new)
        # Another module's look-alike source is left alone.
        self.assertIn("https://example.org/yt-dlp/2020.01.01/yt-dlp", new)
        self.assertIn("c" * 64, new)
        self.assertEqual(up.current_tag(new), "2026.11.30")

    def test_unexpected_manifest(self):
        with self.assertRaises(ValueError):
            up.rewrite_manifest("modules:\n  - name: mpv\n", "2026.11.30", "1" * 64, "2" * 64)
        broken = MANIFEST.replace(f"sha256: {OLD_LIC}", "sha256: nope")
        with self.assertRaises(ValueError):
            up.rewrite_manifest(broken, "2026.11.30", "1" * 64, "2" * 64)

    def test_sums(self):
        sums = f"{'d' * 64}  yt-dlp.exe\n{'e' * 64}  yt-dlp\n{'f' * 64}  yt-dlp_linux\n"
        self.assertEqual(up.sums_entry(sums, "yt-dlp"), "e" * 64)
        self.assertIsNone(up.sums_entry(sums, "yt-dlp_macos"))
        self.assertEqual(up.sums_entry(f"{'AB' * 32}  yt-dlp\n", "yt-dlp"), "ab" * 32)

    def test_notices(self):
        row = "| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | 2026.10.26 | Unlicense | x |"
        self.assertEqual(up.rewrite_notices(row, "2026.11.30"),
                         "| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | 2026.11.30 | Unlicense | x |")

    def test_tags(self):
        self.assertTrue(up.TAG_RE.match("2026.11.30") and up.TAG_RE.match("2026.11.30.1"))
        self.assertFalse(up.TAG_RE.match("nightly") or up.TAG_RE.match("2026.11.30; rm"))

    def test_real_files(self):
        """The real manifest and notices are in the form the rewrite expects."""
        manifest = open(up.MANIFEST, encoding="utf-8").read()
        tag = up.current_tag(manifest)
        self.assertIsNotNone(tag)
        up.rewrite_manifest(manifest, tag, "1" * 64, "2" * 64)
        up.rewrite_notices(open(up.NOTICES, encoding="utf-8").read(), tag)


if __name__ == "__main__":
    unittest.main()
