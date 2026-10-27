"""Compile every shipped ACPI sample without requiring a machine DSDT."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ACPISampleTests(unittest.TestCase):
    def test_thinkpad_sample_matches_export_template(self):
        template = (ROOT / 'HardwareProfiles/SSDT-ThinkPad.template.dsl').read_text(encoding='utf-8')
        source = template.replace('{{ EC_PATH }}', r'\_SB.PCI0.LPCB.EC').replace(
            '{{ HKEY_PATH }}', r'\_SB.PCI0.LPCB.EC.HKEY')
        sample = (ROOT / 'ReYogaSMC/SSDTSample/SSDT-ThinkPad.dsl').read_text(encoding='utf-8')
        self.assertEqual(sample.split('\n', 1)[1], source)
        self.assertNotIn('EST0', source, 'Unreviewed sensor offsets must not be added by the generator')

    @unittest.skipUnless(shutil.which('iasl'), 'ACPI compiler is not installed')
    def test_samples_compile(self):
        with tempfile.TemporaryDirectory() as directory:
            for source in sorted((ROOT / 'ReYogaSMC/SSDTSample').glob('*.dsl')):
                with self.subTest(sample=source.name):
                    result = subprocess.run(['iasl', '-p', str(pathlib.Path(directory) / source.stem), str(source)],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue((pathlib.Path(directory) / (source.stem + '.aml')).is_file())
