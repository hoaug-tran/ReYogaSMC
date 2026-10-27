"""Compile every shipped ACPI sample without requiring a machine DSDT."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ACPISampleTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('iasl'), 'ACPI compiler is not installed')
    def test_samples_compile(self):
        with tempfile.TemporaryDirectory() as directory:
            for source in sorted((ROOT / 'ReYogaSMC/SSDTSample').glob('*.dsl')):
                with self.subTest(sample=source.name):
                    result = subprocess.run(['iasl', '-p', str(pathlib.Path(directory) / source.stem), str(source)],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue((pathlib.Path(directory) / (source.stem + '.aml')).is_file())
