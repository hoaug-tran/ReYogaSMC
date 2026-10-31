"""Run the actual Swift analyzer, then compile and execute its generated AML."""
import base64
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPERS = dict(CSSI=1, RE1B=1, WE1B=2, RECB=2, WECB=3)


def dsdt(ec='EC', methods='', hkey_methods=''):
    return r'''DefinitionBlock ("", "DSDT", 2, "TEST", "ANALYZE", 1) {
    Name (WNTF, Zero) Name (LNUX, Zero)
    Method (XOSI, 1) { Return (Zero) }
    Scope (\_SB) { Device (PCI0) { Name (_HID, "PNP0A08")
    Device (LPCB) { Name (_HID, "PNP0A06")
    Device (ECNAME) { Name (_HID, EisaId ("PNP0C09"))
        OperationRegion (ECOR, EmbeddedControl, Zero, 0x100)
        Field (ECOR, ByteAcc, NoLock, Preserve) { Offset (0x2F), HFSP, 8, Offset (0x84), HSPD, 16 }
        Device (HKEY) { Name (_HID, "LEN0068") HKEY_METHODS }
        METHODS
    } } } }
    Method (CHEK) { Return (CondRefOf (\_SB.PCI0.LPCB.ECNAME.RE1B) + CondRefOf (\_SB.PCI0.LPCB.ECNAME.WE1B)) }
    }'''.replace('ECNAME', ec).replace('HKEY_METHODS', hkey_methods).replace('METHODS', methods)


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class ThinkPadAnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        cls.folder = pathlib.Path(cls.work.name)
        main = cls.folder / 'main.swift'
        main.write_text((ROOT / 'ReYogaSMCApp/Shared/LocalizedKey.swift').read_text(encoding='utf-8') + '\n' +
                        (ROOT / 'ReYogaSMCApp/Hardware/ACPI/ThinkPadACPI.swift').read_text(encoding='utf-8') + '\n' +
                        (ROOT / 'Tests/thinkpad_acpi.swift').read_text(encoding='utf-8'), encoding='utf-8')
        cls.runner = cls.folder / 'analyze'
        result = subprocess.run(['swiftc', '-swift-version', '5', str(main), '-o', str(cls.runner)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            cls.work.cleanup()
            raise AssertionError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def analyze(self, source=None, ec='EC', live=None, extra=()):
        request = dict(ec=rf'\_SB.PCI0.LPCB.{ec}', hkey=rf'\_SB.PCI0.LPCB.{ec}.HKEY',
                       protocolLayout=dict(FanControlOffset=0x2f, FanRPMOffset=0x84),
                       live=live or {key: False for key in HELPERS},
                       template=(ROOT / 'HardwareProfiles/SSDT-ThinkPad.template.dsl').read_text(encoding='utf-8'),
                       tables=[dict(name='DSDT.aml', source=source or dsdt(ec))] + list(extra))
        return self.request(request)

    def request(self, request):
        result = subprocess.run([str(self.runner)], input=json.dumps(request), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_ec_ec0_hec_names_and_region_evidence(self):
        for ec in ['EC', 'EC0', 'H_EC']:
            with self.subTest(ec=ec):
                result = self.analyze(ec=ec)
                self.assertEqual(set(result['report']['added']), set(HELPERS))
                self.assertEqual(result['report']['ecPath'], rf'\_SB.PCI0.LPCB.{ec}')
                self.assertTrue(result['report']['regions'])

    def test_preserve_live_helper_and_parent_scope(self):
        source = dsdt(methods='Method (RE1B, 1) { Return (0x42) }')
        live = {key: key == 'RE1B' for key in HELPERS}
        result = self.analyze(source, live=live)
        self.assertEqual(result['report']['preserved'], ['RE1B'])
        self.assertNotIn('Method (RE1B,', result['source'])
        evidence = next(x for x in result['report']['helpers'] if x['path'].endswith('RE1B'))
        self.assertEqual(evidence['definitions'][0]['table'], 'DSDT.aml')
        self.assertGreater(evidence['definitions'][0]['line'], 0)

    def test_reject_wrong_arity_field_collision_inactive_and_duplicates(self):
        for methods in ['Method (RE1B, 2) {}', 'Name (RE1B, One)',
                        'Field (ECOR, ByteAcc, NoLock, Preserve) { RE1B, 8 }',
                        'Method (RE1B, 1) {}', 'Method (RE1B, 1) {} Method (RE1B, 1) {}']:
            with self.subTest(methods=methods):
                self.assertIn('error', self.analyze(dsdt(methods=methods)))

    def test_missing_capture_or_unmatched_ec_is_not_a_best_guess(self):
        result = self.analyze(dsdt().replace('"PNP0C09"', '"ACID0001"'))
        self.assertIn('PNP0C09', result['error'])
        result = self.analyze(dsdt().replace('Device (HKEY)', 'Device (VPC0)'))
        self.assertIn('relationship', result['error'])
        result = self.analyze(live={'RE1B': False})
        self.assertIn('evidence', result['error'])

    def test_comments_strings_and_padded_names_do_not_create_methods(self):
        source = dsdt('EC__').replace('OperationRegion', '// Method (RE1B, 2) { }\n OperationRegion')
        source = source.replace('Name (WNTF, Zero)', 'Name (NOTE, "Method (WE1B, 4) {}") Name (WNTF, Zero)')
        result = self.analyze(source)
        self.assertEqual(set(result['report']['added']), set(HELPERS))

    def test_existing_ssdt_scope_is_used_and_xosi_is_reported(self):
        patch = r'''DefinitionBlock ("", "SSDT", 2, "TEST", "EXISTING", 1) {
        Scope (\_SB.PCI0.LPCB.EC.HKEY) { Method (CSSI, 1) {} }
        Method (XOSI, 1) { Return (Zero) }
        }'''
        result = self.analyze(live={key: key == 'CSSI' for key in HELPERS},
                              extra=[dict(name='existing.aml', source=patch)])
        self.assertEqual(result['report']['preserved'], ['CSSI'])
        self.assertTrue(result['report']['warnings'])

    def test_fan_layout_must_be_statically_proven_before_adding_ec_writes(self):
        for source in [dsdt().replace('HFSP, 8', 'HFSP, 16'), dsdt().replace('Offset (0x2F)', 'Offset (0x3F)'),
                       dsdt().replace('HFSP, 8', 'HFSP, SIZE'), dsdt().replace('EmbeddedControl', 'SystemMemory'),
                       dsdt().replace('HSPD, 16', 'HSPD, 8'), dsdt().replace('Offset (0x84)', 'Offset (0x85)'),
                       dsdt().replace('Offset (0x84)', 'Offset (DYN0)'), dsdt().replace('Zero, 0x100', 'One, 0xFF')]:
            self.assertIn('do not match', self.analyze(source)['error'])
        source = dsdt().replace('Offset (0x2F)', 'DYN0, SIZE, Offset (0x2F)')
        self.assertTrue(self.analyze(source)['report']['fanLayout']['verified'])

    def test_parent_scope_and_aliases_never_bypass_helper_collision(self):
        patch = r'''DefinitionBlock ("", "SSDT", 2, "TEST", "ALIAS", 1) {
        Scope (\_SB.PCI0.LPCB.EC.HKEY) { Method (^RE1B, 2) {} }
        }'''
        self.assertIn('Conflicting', self.analyze(extra=[dict(name='parent.aml', source=patch)])['error'])
        self.assertIn('Conflicting', self.analyze(dsdt(methods='Alias (HSPD, RE1B)'))['error'])

    def test_all_present_is_no_patch_needed(self):
        source = dsdt(methods=' '.join(f'Method ({key}, {argc}) {{}}' for key, argc in HELPERS.items() if key != 'CSSI'),
                      hkey_methods='Method (CSSI, 1) {}')
        self.assertIn('no SSDT is needed', self.analyze(source, live={key: True for key in HELPERS})['error'])

    def test_table_checksum_size_and_signature(self):
        def table(signature):
            data = bytearray(36)
            data[:4] = signature.encode()
            data[4:8] = len(data).to_bytes(4, 'little')
            data[9] = -sum(data) & 255
            return data
        dsdt_table, ssdt_table = table('DSDT'), table('SSDT')
        encode = lambda tables: dict(aml=[base64.b64encode(x).decode() for x in tables])
        self.assertTrue(self.request(encode([dsdt_table, ssdt_table]))['valid'])
        for tables in [[], [ssdt_table], [dsdt_table, table('MSDM')], [dsdt_table[:-1]]]:
            self.assertIn('error', self.request(encode(tables)))
        dsdt_table[10] ^= 1
        self.assertIn('checksum', self.request(encode([dsdt_table]))['error'])

    def test_reboot_verification_rejects_missing_manifest_table_or_capability(self):
        live = {key: True for key in HELPERS}
        live['ECCapability'] = 'RW'
        request = dict(expected='fingerprint', loaded=['fingerprint'], live=live)
        self.assertTrue(self.request(dict(verify=request))['valid'])
        for change in [dict(expected=None), dict(loaded=[]), dict(live={**live, 'RE1B': False}), dict(live={**live, 'ECCapability': 'RO'})]:
            self.assertIn('error', self.request(dict(verify={**request, **change})))

    def test_installed_aml_normalizes_only_osi_rename_and_checksum(self):
        original = bytearray(36) + b'_OSI'
        renamed = bytearray(original)
        renamed[-4:] = b'XOSI'; renamed[9] = 44
        changed = bytearray(renamed); changed[-1] = ord('X')
        response = self.request(dict(normalize=[base64.b64encode(x).decode() for x in [original, renamed, changed]]))['normalized']
        self.assertEqual(response[0], response[1])
        self.assertNotEqual(response[0], response[2])

    def test_real_localization_renders_vietnamese_and_preserves_namespace(self):
        for key, phrase in [('Conflicting object or method argument count at %@', 'Xung đột'),
                            ('Full Speed', 'Tốc độ tối đa'), ('BIOS Auto', 'BIOS')]:
            translated = self.request(dict(localize=dict(bundle=str(ROOT / 'vi.lproj'), key=key)))['text']
            self.assertIn(phrase, translated)
            if '%@' in key:
                self.assertIn('EC0', translated)
                self.assertNotIn('%@', translated)

    @unittest.skipUnless(shutil.which('iasl') and shutil.which('acpiexec'), 'ACPICA runtime required')
    def test_generated_helpers_survive_global_osi_rename(self):
        result = self.analyze()
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            for name, source in [('base', dsdt()), ('generated', result['source'])]:
                path = directory / (name + '.dsl')
                path.write_text(source, encoding='utf-8')
                compile_result = subprocess.run(['iasl', '-p', str(directory / name), str(path)],
                                                capture_output=True, text=True, timeout=15)
                self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            path = directory / 'generated.aml'
            data = bytearray(path.read_bytes().replace(b'_OSI', b'XOSI'))
            data[9] = (data[9] - sum(data)) & 255
            path.write_bytes(data)
            runtime = subprocess.run(['acpiexec', '-b', 'osi install Darwin; load generated.aml; execute CHEK', 'base.aml'],
                                     cwd=directory, capture_output=True, text=True, timeout=15)
            self.assertIn('[Integer] = FFFFFFFFFFFFFFFE', runtime.stdout + runtime.stderr)
            self.assertNotIn('AE_ALREADY_EXISTS', runtime.stdout + runtime.stderr)
