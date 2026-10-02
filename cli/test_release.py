import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_multiple_go_json_objects(self):
        self.assertEqual(list(release.decode_objects(' \n{"Module":{"Path":"a"}}\n {"Standard":true}\n')),
                         [{"Module": {"Path": "a"}}, {"Standard": True}])

    def test_nested_notices_are_preserved_without_copying_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            destination = Path(tmp) / "licenses"
            (source / "nested").mkdir(parents=True)
            texts = {"LICENSE.txt": b"Copyright A\r\nMIT license\r\n",
                     "NOTICE": b"Additional attribution\n",
                     "nested/COPYING": b"Different license\n"}
            for name, data in texts.items():
                (source / name).write_bytes(data)
            (source / "code.go").write_text("package example")
            self.assertEqual(release.copy_notices(source, destination), sorted(texts))
            for name, data in texts.items():
                self.assertEqual((destination / name).read_bytes(), data)
            self.assertFalse((destination / "code.go").exists())

    def test_versioned_module_notice_and_go_runtime_are_included(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            module, goroot, stage = root / "module", root / "go", root / "stage"
            module.mkdir()
            stage.mkdir()
            (goroot / "src" / "vendor").mkdir(parents=True)
            (module / "LICENSE").write_text("module license")
            (module / "NOTICE").write_text("module attribution")
            (goroot / "LICENSE").write_text("Go license")
            (goroot / "PATENTS").write_text("Go patent grant")
            (goroot / "src" / "vendor" / "LICENSE").write_text("vendored license")
            release.collect_licenses(stage, [{"Module": {"Path": "example.org/module",
                                     "Version": "v1.2.3", "Dir": str(module)}}], goroot, "go1.26.8")
            notices = stage / "licenses/modules/example.org/module@v1.2.3"
            self.assertEqual((notices / "NOTICE").read_text(), "module attribution")
            self.assertEqual((stage / "licenses/go/LICENSE").read_text(), "Go license")
            self.assertEqual((stage / "licenses/go/src/vendor/LICENSE").read_text(), "vendored license")
            index = (stage / "THIRD_PARTY_NOTICES.md").read_text()
            self.assertIn("example.org/module v1.2.3", index)
            self.assertIn("Built with go1.26.8", index)

    def test_missing_license_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            source.mkdir()
            (source / "NOTICE").write_text("Attribution alone is not a license")
            with self.assertRaisesRegex(RuntimeError, "No license text"):
                release.copy_notices(source, Path(tmp) / "destination")


if __name__ == "__main__":
    unittest.main()
