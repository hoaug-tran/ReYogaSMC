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
