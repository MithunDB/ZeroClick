"""Run with Python 3, Pillow, and cryptography installed."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("zeroclick_stego", ROOT / "scripts/zeroclick-stego.py")
assert SPEC and SPEC.loader
stego = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stego)


class PortabilityTests(unittest.TestCase):
    def test_swift_written_png_opens_in_portable_reader(self):
        fixture = ROOT / "Tests/Fixtures/zeroclick-native-message.png"
        payload = stego.hidden_bytes(stego.pixels_for(fixture)[0])
        self.assertEqual(stego.open_payload(payload, "test-stego-42"), "Meet at café ☕️")
        with self.assertRaisesRegex(ValueError, "Incorrect password"):
            stego.open_payload(payload, "wrong")

    def test_portable_writer_fixture_still_opens(self):
        fixture = ROOT / "Tests/Fixtures/zeroclick-portable-message.png"
        payload = stego.hidden_bytes(stego.pixels_for(fixture)[0])
        self.assertEqual(stego.open_payload(payload, "interop-test-42"), "Portable café ☕️")

    def test_new_copy_never_replaces_source_or_occupied_output(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "cover.png"
            output = Path(folder) / "hidden.png"
            Image.new("RGBA", (128, 128), (35, 120, 200, 255)).save(source)
            original = source.read_bytes()
            stego.hide(source, output, "Portable test", "sample-password")
            saved = output.read_bytes()
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(
                stego.open_payload(stego.hidden_bytes(stego.pixels_for(output)[0]), "sample-password"),
                "Portable test",
            )
            with self.assertRaisesRegex(ValueError, "Output already exists"):
                stego.hide(source, output, "replacement", "sample-password")
            self.assertEqual(output.read_bytes(), saved)


if __name__ == "__main__":
    unittest.main()
