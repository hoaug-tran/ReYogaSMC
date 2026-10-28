"""Execute portable kernel policy; enable memory/UB checks on macOS and Linux."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class FirmwareIdentityTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang++') or shutil.which('g++'), 'C++ compiler required')
    def test_kernel_identity_matrix(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = pathlib.Path(directory) / ('firmware-identity.exe' if sys.platform == 'win32' else 'firmware-identity')
            compiler = shutil.which('clang++') if sys.platform != 'win32' else (shutil.which('g++') or shutil.which('clang++'))
            sanitizers = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sys.platform != 'win32' else []
            subprocess.run([compiler or shutil.which('g++'), '-std=c++14', '-Wall', '-Wextra', '-Werror',
                            *sanitizers,
                            str(ROOT / 'Tests/firmware_identity.cpp'), '-o', str(executable)],
                           check=True, capture_output=True, text=True, timeout=60)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
