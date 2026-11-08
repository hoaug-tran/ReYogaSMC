"""Regression tests for ACPI disassembly safety, two-tier strategy, and secondary table tolerance."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

try:
    from .source_tools import app_sources, function
except ImportError:
    from source_tools import app_sources, function

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ACPISafetyTests(unittest.TestCase):
    def test_thinkpad_acpi_export_disassembly_contracts(self):
        body = (ROOT / 'ReYogaSMCApp/Hardware/ACPI/ACPIExport.swift').read_text(encoding='utf-8')
        export = function(body, 'static func exportThinkPadSSDT(')

        # 1. 4MB buffer limit (matching compileSSDT)
        self.assertIn('4 * 1024 * 1024', export)

        # 2. Independent DSDT disassembly without -e context
        self.assertIn('let isDSDT = (index == 0)', export)
        self.assertIn('["-dl", "-d", input]', export)

        # 3. Two-tier SSDT disassembly with DSDT context and independent fallback
        self.assertIn('let dsdtPath = inputs[0]', export)
        self.assertIn('["-dl", "-e", dsdtPath, "-d", input]', export)
        self.assertIn('["-dl", "-d", input]', export)
        self.assertIn('AE_ALREADY_EXISTS', export)

        # 4. Artifact-based validation (dsl exists and size > 0, not exit code == 0)
        self.assertIn('hasValidArtifact', export)
        self.assertIn('size.intValue > 0', export)
        self.assertNotIn('disassembly["state"] as? String == "completed"', export)

        # 5. Fault tolerance for secondary tables: warnings instead of fatal errors
        self.assertIn('report["warnings"]', export)
        self.assertIn('Failed to disassemble', export)

    @unittest.skipUnless(shutil.which('iasl'), 'iasl compiler required')
    def test_iasl_two_tier_disassembly_and_collision_fallback(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            work = pathlib.Path(temp_dir)

            dsdt_asl = (
                'DefinitionBlock ("table-000.aml", "DSDT", 2, "TEST", "DSDT0001", 1) {\n'
                '    Scope (\\_SB) {\n'
                '        Device (PCI0) {\n'
                '            Name (_HID, "PNP0A08")\n'
                '            Device (LPCB) {\n'
                '                Name (_HID, "PNP0A06")\n'
                '                Device (EC) {\n'
                '                    Name (_HID, "PNP0C09")\n'
                '                    Name (HKEY, 1)\n'
                '                }\n'
                '            }\n'
                '        }\n'
                '    }\n'
                '}\n'
            )

            ssdt_collision_asl = (
                'DefinitionBlock ("table-001.aml", "SSDT", 2, "TEST", "SSDTCOLL", 1) {\n'
                '    External (\\_SB.PCI0.LPCB, DeviceObj)\n'
                '    Scope (\\_SB.PCI0.LPCB) {\n'
                '        Device (EC) {\n'
                '            Name (_HID, "COLL0001")\n'
                '        }\n'
                '    }\n'
                '}\n'
            )

            dsdt_file = work / 'table-000.dsl'
            ssdt_file = work / 'table-001.dsl'

            dsdt_file.write_text(dsdt_asl, encoding='utf-8')
            ssdt_file.write_text(ssdt_collision_asl, encoding='utf-8')

            # Compile both to AML
            for src in (dsdt_file, ssdt_file):
                res = subprocess.run(['iasl', '-p', str(work / src.stem), str(src)],
                                     capture_output=True, text=True, timeout=15)
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

            # Remove DSL sources
            dsdt_file.unlink()
            ssdt_file.unlink()

            dsdt_aml = work / 'table-000.aml'
            ssdt_aml = work / 'table-001.aml'

            # 1. Independent DSDT disassembly succeeds
            res_dsdt = subprocess.run(['iasl', '-dl', '-d', str(dsdt_aml)],
                                      cwd=work, capture_output=True, text=True, timeout=15)
            self.assertTrue(dsdt_file.is_file())
            self.assertGreater(dsdt_file.stat().st_size, 0)

            # 2. SSDT with DSDT context encounters namespace collision (AE_ALREADY_EXISTS)
            res_ssdt_context = subprocess.run(
                ['iasl', '-dl', '-e', str(dsdt_aml), '-d', str(ssdt_aml)],
                cwd=work, capture_output=True, text=True, timeout=15
            )
            collision_detected = (
                'AE_ALREADY_EXISTS' in (res_ssdt_context.stdout + res_ssdt_context.stderr)
                or not ssdt_file.is_file()
                or ssdt_file.stat().st_size == 0
            )
            self.assertTrue(collision_detected, 'Namespace collision should be triggered or artifact missing')

            # Clean up if partial artifact was generated
            if ssdt_file.is_file():
                ssdt_file.unlink()

            # 3. Fallback independent disassembly succeeds and produces artifact
            res_ssdt_fallback = subprocess.run(
                ['iasl', '-dl', '-d', str(ssdt_aml)],
                cwd=work, capture_output=True, text=True, timeout=15
            )
            self.assertTrue(ssdt_file.is_file(), 'Fallback independent disassembly must create dsl artifact')
            self.assertGreater(ssdt_file.stat().st_size, 0)


if __name__ == '__main__':
    unittest.main()
