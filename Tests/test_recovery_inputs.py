import hashlib
import importlib.util
import pathlib
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

support = load('hardware_support')
release = load('release')

class RecoveryInputTests(unittest.TestCase):
    def test_valid_fingerprint_unchanged(self):
        for source in ['Name (X, 1) /* ignored */', 'Name(X,"a /* x */ // b") // end\n', '/*x*/ Name(X, "a b")']:
            tokens = re.findall(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[^\s]', source, re.S)
            expected = hashlib.sha256(''.join(t for t in tokens if not t.startswith(('/*', '//'))).encode()).hexdigest()
            self.assertEqual(support.normalized_hash(source), expected)

    def test_unterminated_comment_rejected(self):
        for size in [3000, 12000, 100000]:
            with self.assertRaisesRegex(ValueError, 'Unterminated'):
                support.normalized_hash('/*x' * size)

    def test_dsl_size_boundary(self):
        with patch.object(support, 'MAX_DSL_BYTES', 16), tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'test.dsl'
            path.write_bytes(b'x' * 16)
            self.assertEqual(support.read_dsl(path), 'x' * 16)
            path.write_bytes(b'x' * 17)
            with self.assertRaises(ValueError):
                support.read_dsl(path)
            with self.assertRaises(ValueError):
                support.normalized_hash('x' * 17)

    def test_localization_only_plan_publishes(self):
        for path in ['en.lproj/Localizable.strings', 'vi.lproj/Localizable.strings']:
            def git(*args):
                if args[0] == 'tag': return 'v2.1.1'
                if args[0] == 'rev-parse': return 'current'
                if args[0] == 'diff': return path
                if args[0] == 'log': return 'fix: translations'
                if args[0] == 'ls-files': return path
                if args[0] == 'rev-list': return 'previous'
                raise AssertionError(args)
            with patch.object(release, 'git', git):
                self.assertTrue(release.plan()['publish'])

    def test_swift_recovery_and_input_guards(self):
        helper = (ROOT / 'ReYogaSMCUtils/ThinkFanHelper.swift').read_text()
        views = (ROOT / 'ReYogaSMCApp/HardwareViews.swift').read_text()
        manager = (ROOT / 'ReYogaSMCApp/HardwareManager.swift').read_text()
        backend = (ROOT / 'ReYogaSMCApp/HardwareSupport.swift').read_text()
        self.assertIn('enable || automatic', helper)
        self.assertIn('guard sample[2] & 0x80 != 0', helper)
        self.assertIn('command(index, automatic: true)', views)
        self.assertIn('rgbController.status.available && rgbPreference?', manager)
        self.assertIn('read(upToCount: SavedRGBSettings.maximumImportBytes + 1)', manager)
        self.assertIn('guard data.count <= SavedRGBSettings.maximumImportBytes', backend)
        self.assertIn('with administrator privileges', backend)
        self.assertIn('manifest.append(try collectPrivileged(to: folder))', backend)
        self.assertIn('password never read or stored', backend)
        self.assertNotIn('sudo -S', backend)

        self.assertIn('data.count <= SavedRGBSettings.maximumSavedBytes', manager)
        self.assertIn('"DYTC"', manager)
        self.assertIn('report["driverRegistry"]', manager)
        self.assertIn('expectedDriverFieldsMissing', manager)
        self.assertIn('uptimeSeconds', manager)
        self.assertIn('Event exceeds 1 MiB', manager)
        kernel = (ROOT / 'ReYogaSMC/ReYogaVPC.cpp').read_text()
        self.assertIn('"LastDYTCMutation"', kernel)
        self.assertIn('"TransportStatus", transport', kernel)


if __name__ == '__main__':
    unittest.main()
