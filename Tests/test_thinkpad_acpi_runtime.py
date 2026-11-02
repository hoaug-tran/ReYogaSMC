"""Execute the exported AML with pre-existing helpers, not just compile it."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('iasl') and shutil.which('acpiexec'), 'ACPICA tools required')
class ThinkPadACPIRuntimeTests(unittest.TestCase):
    def test_existing_helpers_and_os_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = pathlib.Path(directory)
            base = r'''DefinitionBlock ("", "DSDT", 2, "TEST", "THINK", 1) {
                Name (WNTF, Zero) Name (LNUX, Zero)
                Scope (\_SB) { Device (PCI0) { Name (_HID, "PNP0A08")
                  Device (LPCB) { Name (_HID, "PNP0A06")
                    Device (EC) { Name (_HID, "PNP0C09")
                      Device (HKEY) { Name (_HID, "LEN0068") Method (CSSI, 1) {} }
                      Method (RE1B, 1) { Return (0x42) }
                      Method (WE1B, 2) {} Method (RECB, 2) { Return (Buffer (1) {0x42}) }
                      Method (WECB, 3) {}
                } } } }
                Method (MAIN) { Return (\_SB.PCI0.LPCB.EC.RE1B (Zero)) }
            }'''
            template = (ROOT / 'HardwareProfiles/SSDT-ThinkPad.template.dsl').read_text(encoding='utf-8')
            generated = template.replace('{{ EC_PATH }}', r'\_SB.PCI0.LPCB.EC').replace(
                '{{ HKEY_PATH }}', r'\_SB.PCI0.LPCB.EC.HKEY')
            # Exercise another real namespace shape and partial/absent prior patches.
            for mode, ec_name in [('all', 'EC'), ('partial', 'H_EC'), ('none', 'EC'), ('none', 'EC0')]:
                with self.subTest(mode=mode, ec=ec_name):
                    fixture = base
                    if mode != 'all':
                        fixture = fixture.replace('Method (CSSI, 1) {}', '')
                        fixture = fixture.replace('Method (WE1B, 2) {}', '').replace('Method (WECB, 3) {}', '')
                        fixture = fixture.replace('Method (RECB, 2) { Return (Buffer (1) {0x42}) }', '')
                    if mode == 'none':
                        fixture = fixture.replace('Method (RE1B, 1) { Return (0x42) }', '')
                        fixture = fixture.replace(r'Return (\_SB.PCI0.LPCB.EC.RE1B (Zero))', 'Return (Zero)')
                    fixture = fixture.replace('Device (EC)', f'Device ({ec_name})').replace('.EC.', f'.{ec_name}.')
                    if ec_name == 'EC0':
                        fixture = fixture.rsplit('}', 1)[0] + r'''
                            Scope (\_SB) { Device (EC) { Name (_HID, "ACID0001") } }
                        }'''
                    patch = generated.replace('.EC', f'.{ec_name}')
                    ec = rf'\_SB.PCI0.LPCB.{ec_name}'
                    paths = [ec + '.HKEY.CSSI'] + [ec + '.' + name for name in ('RE1B', 'WE1B', 'RECB', 'WECB')]
                    check = '\n Method (CHEK) { Return (' + ' + '.join(f'ObjectType ({path})' for path in paths) + ') }\n'
                    patch = patch.rsplit('}', 1)[0] + check + '}\n'
                    for name, source in [('base', fixture), ('generated', patch)]:
                        path = folder / (name + '.dsl')
                        path.write_text(source, encoding='utf-8')
                        result = subprocess.run(['iasl', '-p', str(folder / name), str(path)],
                                                capture_output=True, text=True, timeout=15)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    result = subprocess.run(['acpiexec', '-b', 'osi install Darwin; load generated.aml; execute WNTF; execute LNUX; execute MAIN; execute CHEK',
                                             'base.aml'], cwd=folder, capture_output=True, text=True, timeout=15)
                    output = result.stdout + result.stderr
                    self.assertNotIn('AE_ALREADY_EXISTS', output)
                    self.assertNotIn('AE_NOT_FOUND', output)
                    self.assertEqual(output.count('[Integer] = 0000000000000001'), 2, output)
                    self.assertIn('[Integer] = 0000000000000028', output, 'All five helpers must remain methods')
                    if mode != 'none':
                        self.assertIn('[Integer] = 0000000000000042', output, 'Preserve original RE1B')

    def test_thermal_unlock_pl1s_override(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = pathlib.Path(directory)
            template = (ROOT / 'HardwareProfiles/SSDT-ThinkPad.template.dsl').read_text(encoding='utf-8')
            ssdt_source = template.replace('{{ EC_PATH }}', r'\_SB.PCI0.LPCB.EC').replace(
                '{{ HKEY_PATH }}', r'\_SB.PCI0.LPCB.EC.HKEY')
            (folder / 'ssdt.dsl').write_text(ssdt_source, encoding='utf-8')
            res = subprocess.run(['iasl', '-p', str(folder / 'ssdt'), str(folder / 'ssdt.dsl')],
                                 capture_output=True, text=True, timeout=15)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

            cases = [
                (2, 0, 0x60, 0x0198, 'SMMC=2 overrides 0x60 to 0x0198'),
                (0, 7, 0x60, 0x0198, 'SPSC=7 overrides 0x60 to 0x0198'),
                (0, 8, 0x60, 0x0198, 'SPSC=8 overrides 0x60 to 0x0198'),
                (1, 0, 0x60, 0x60, 'SMMC=1 preserves 0x60 intact'),
                (0, 4, 0x60, 0x60, 'SPSC=4 preserves 0x60 intact'),
                (2, 0, 0x28, 0x28, 'Emergency STP 0x28 preserved intact in Performance mode'),
            ]

            for smmc, spsc, in_val, exp_val, desc in cases:
                with self.subTest(desc=desc):
                    dsdt = f'''DefinitionBlock ("", "DSDT", 2, "TEST", "THINK", 1) {{
                        Name (SMMC, {smmc:#x})
                        Name (SPSC, {spsc:#x})
                        Scope (\\_SB) {{
                            Device (PCI0) {{
                                Name (_HID, "PNP0A08")
                                Name (LAST, Zero)
                                Method (XL1S, 1, NotSerialized) {{
                                    LAST = Arg0
                                }}
                                Device (LPCB) {{
                                    Name (_HID, "PNP0A06")
                                    Device (EC) {{
                                        Name (_HID, "PNP0C09")
                                        Device (HKEY) {{
                                            Name (_HID, "LEN0068")
                                        }}
                                    }}
                                }}
                            }}
                        }}
                    }}'''
                    (folder / 'dsdt.dsl').write_text(dsdt, encoding='utf-8')
                    res = subprocess.run(['iasl', '-p', str(folder / 'dsdt'), str(folder / 'dsdt.dsl')],
                                         capture_output=True, text=True, timeout=15)
                    self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                    cmd = f'load ssdt.aml; execute \\_SB.PCI0.PL1S {in_val:#x}; execute \\_SB.PCI0.LAST'
                    result = subprocess.run(['acpiexec', '-b', cmd, 'dsdt.aml'], cwd=folder,
                                            capture_output=True, text=True, timeout=15)
                    output = result.stdout + result.stderr
                    self.assertNotIn('AE_ALREADY_EXISTS', output)
                    self.assertNotIn('AE_NOT_FOUND', output)
                    expected_hex = f'{exp_val:016X}'
                    self.assertIn(f'[Integer] = {expected_hex}', output, f'Expected LAST to be {exp_val:#x}')

    def test_thermal_unlock_t490_pl1s_override(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = pathlib.Path(directory)
            t490_source = (ROOT / 'ReYogaSMC/ACPIExamples/SSDT-ThinkPad-T490.dsl').read_text(encoding='utf-8')
            (folder / 'ssdt.dsl').write_text(t490_source, encoding='utf-8')
            res = subprocess.run(['iasl', '-p', str(folder / 'ssdt'), str(folder / 'ssdt.dsl')],
                                 capture_output=True, text=True, timeout=15)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

            cases = [
                (2, 0, 0x60, 0x00C8, 'T490 SMMC=2 overrides 0x60 to 0x00C8 (25W)'),
                (0, 7, 0x60, 0x00C8, 'T490 SPSC=7 overrides 0x60 to 0x00C8 (25W)'),
                (0, 8, 0x60, 0x00C8, 'T490 SPSC=8 overrides 0x60 to 0x00C8 (25W)'),
                (1, 0, 0x60, 0x60, 'T490 SMMC=1 preserves 0x60 intact'),
                (2, 0, 0x28, 0x28, 'T490 Emergency STP 0x28 preserved intact'),
            ]

            for smmc, spsc, in_val, exp_val, desc in cases:
                with self.subTest(desc=desc):
                    dsdt = f'''DefinitionBlock ("", "DSDT", 2, "TEST", "THINK", 1) {{
                        Name (SMMC, {smmc:#x})
                        Name (SPSC, {spsc:#x})
                        Scope (\\_SB) {{
                            Device (PCI0) {{
                                Name (_HID, "PNP0A08")
                                Name (LAST, Zero)
                                Method (XL1S, 1, NotSerialized) {{
                                    LAST = Arg0
                                }}
                                Device (LPCB) {{
                                    Name (_HID, "PNP0A06")
                                    Device (EC) {{
                                        Name (_HID, "PNP0C09")
                                        Device (HKEY) {{
                                            Name (_HID, "LEN0068")
                                        }}
                                    }}
                                }}
                            }}
                        }}
                    }}'''
                    (folder / 'dsdt.dsl').write_text(dsdt, encoding='utf-8')
                    res = subprocess.run(['iasl', '-p', str(folder / 'dsdt'), str(folder / 'dsdt.dsl')],
                                         capture_output=True, text=True, timeout=15)
                    self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                    cmd = f'load ssdt.aml; execute \\_SB.PCI0.PL1S {in_val:#x}; execute \\_SB.PCI0.LAST'
                    result = subprocess.run(['acpiexec', '-b', cmd, 'dsdt.aml'], cwd=folder,
                                            capture_output=True, text=True, timeout=15)
                    output = result.stdout + result.stderr
                    self.assertNotIn('AE_ALREADY_EXISTS', output)
                    self.assertNotIn('AE_NOT_FOUND', output)
                    expected_hex = f'{exp_val:016X}'
                    self.assertIn(f'[Integer] = {expected_hex}', output, f'Expected LAST to be {exp_val:#x}')
