"""Execute the kernel's portable identity logic with memory and UB checks."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class FirmwareIdentityTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang++') and sys.platform != 'win32', 'native sanitizer test requires macOS/Linux clang++')
    def test_kernel_identity_matrix(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = pathlib.Path(directory) / 'firmware-identity'
            subprocess.run(['clang++', '-std=c++14', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                            str(ROOT / 'Tests/firmware_identity.cpp'), '-o', str(executable)],
                           check=True, capture_output=True, text=True, timeout=60)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
