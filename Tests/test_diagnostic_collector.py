"""Execute production diagnostic process limits on macOS and Linux."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    from .source_tools import function
except ImportError:
    from source_tools import function

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc') and sys.platform in ('darwin', 'linux'),
                     'Swift compiler on macOS or Linux required')
class DiagnosticCollectorTests(unittest.TestCase):
    def test_production_process_limits(self):
        source = (ROOT / 'ReYogaSMCApp/Diagnostics/DiagnosticCollector.swift').read_text(encoding='utf-8')
        if sys.platform == 'linux':
            source = source.replace('import Darwin', 'import Glibc')
        checks = (ROOT / 'Tests/main.swift').read_text(encoding='utf-8')
        source += '\n' + function(checks, 'func require(') + '\n' + function(checks, 'func testDiagnostics()')
        source += '\ntry testDiagnostics()\n'
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / 'main.swift'
            main.write_text(source, encoding='utf-8')
            executable = pathlib.Path(directory) / 'diagnostics'
            build = subprocess.run(['swiftc', '-swift-version', '5', str(main), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
