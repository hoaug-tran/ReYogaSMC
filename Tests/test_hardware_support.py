"""Profile trust boundaries and report recovery, without firmware calls."""
import copy
import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('hardware_support', ROOT / 'Scripts/hardware_support.py')
support = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support)


class HardwareSupportTests(unittest.TestCase):
    def test_reviewed_legion_battery_mapping_does_not_swap_charge_modes(self):
        profile = json.loads((ROOT / 'HardwareProfiles/legion7-16achg6.json').read_text(encoding='utf-8'))
        # Lenovo Storage uses BTSM/bit 5; Quick uses QCHO/bit 2.
        samples = [(0x10060020, True, False), (0x10060204, False, True), (0x10060000, False, False)]
        for raw, conservation, rapid in samples:
            self.assertEqual(bool(raw & profile['battery_conservation_mask']), conservation)
            self.assertEqual(bool(raw & profile['battery_rapidcharge_mask']), rapid)
        self.assertEqual(profile['battery_conservation_mask'] & profile['battery_rapidcharge_mask'], 0)

    def test_battery_commands_change_the_same_state_that_is_read(self):
        profile = json.loads((ROOT / 'HardwareProfiles/legion7-16achg6.json').read_text(encoding='utf-8'))
        # SBMC writes from the DSDT; Storage/Quick semantics from Toolkit and LenovoLegionLinux.
        def sbmc(command, qcho, btsm):
            if command == 3: btsm = True
            elif command == 5: btsm = False
            elif command == 7: qcho, btsm = True, False
            elif command == 8: qcho = False
            else: self.fail('Unreviewed battery command')
            return (4 if qcho else 0) | (32 if btsm else 0)
        for mode, mask, initial in [('conservation', 32, (False, False)), ('rapidcharge', 4, (False, True))]:
            enabled = sbmc(profile[f'battery_{mode}_on'], *initial)
            self.assertTrue(enabled & mask)
            disabled = sbmc(profile[f'battery_{mode}_off'], bool(enabled & 4), bool(enabled & 32))
            self.assertFalse(disabled & mask)
        self.assertFalse(sbmc(profile['battery_rapidcharge_on'], False, True) & 32)
        self.assertEqual((profile['battery_conservation_on'], profile['battery_conservation_off']), (3, 5))
        self.assertEqual((profile['battery_rapidcharge_on'], profile['battery_rapidcharge_off']), (7, 8))
        self.assertEqual(profile['battery_conservation_capability_mask'], 0)
        self.assertEqual(profile['battery_rapidcharge_capability_mask'], 1 << 17)
        self.assertEqual(profile['battery_mapping_version'], 4)
        bridge = support.render(profile)
        for method, key in [('RYCO', 'conservation_on'), ('RYCF', 'conservation_off'), ('RYRO', 'rapidcharge_on'), ('RYRF', 'rapidcharge_off')]:
            self.assertIn(f'Method ({method}, 0, Serialized) {{ Return ({profile["battery_" + key]}) }}', bridge)

    def test_unrelated_firmware_table_is_not_exported(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'MSDM.aml'
            path.write_bytes(b'MSDM' + b'private-license-data')
            self.assertEqual(support.table_signature(path), 'MSDM')
            output = pathlib.Path(tmp) / 'report'
            result = subprocess.run([sys.executable, str(ROOT / 'Scripts/hardware_support.py'),
                                     '--acpi', str(path), '--output', str(output), '--offline'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((output / 'report.json').read_text(encoding='utf-8'))
            self.assertTrue(report['excluded_tables'])
            self.assertEqual(list((output / 'tables').iterdir()), [])

    def test_static_field_offsets_do_not_cross_dynamic_lengths(self):
        source = """/* first line
        second line */
        OperationRegion (ERAM, SystemMemory, 0x1000, 0x100)
        Field (ERAM, ByteAcc, NoLock, Preserve) {
            Offset (0x10), STAT, 1, , 3, FLAG, 4,
            DYN0, SIZE, NEXT, 8, Offset (0x20), RPM0, 16
        }"""
        fields = {item['name']: item for item in support.scan(source)['fields']}
        self.assertEqual(fields['FLAG']['byte_offset'], 0x10)
        self.assertEqual(fields['FLAG']['bit_in_byte'], 4)
        self.assertIsNone(fields['NEXT']['bit_offset'])
        self.assertEqual(fields['RPM0']['declared_memory_address'], '0x1020')
        self.assertEqual(fields['STAT']['declaration_line'], 4)

    def test_wmi_guid_endianness_and_event_flags(self):
        import uuid
        guid = uuid.UUID('8c5b9127-ecd4-4657-980f-851019f99ca5')
        row = guid.bytes_le + b'BA' + bytes([1, 2])
        text = ', '.join(hex(x) for x in row)
        result = support.decode_wdg([text])[0]
        self.assertEqual(result['guid'], str(guid))
        self.assertEqual(result['object_id'], 'BA')
        self.assertTrue(result['method'])
        self.assertFalse(result['event'])

    def test_patterns_without_fingerprint_are_not_trusted(self):
        source = 'Method (GBMD, 0, NotSerialized) { Return (Zero) }'
        profile = {'required_patterns': ['GBMD'], 'reviewed_dsdt_hashes': []}
        with self.assertRaises(ValueError):
            support.match_profile(source, [profile])

    def test_identity_and_required_interface_both_must_match(self):
        source = 'Method (GBMD, 0, NotSerialized) { Return (Zero) }'
        profile = {'required_patterns': ['SBMC'], 'reviewed_dsdt_hashes': [support.normalized_hash(source)]}
        with self.assertRaises(ValueError):
            support.match_profile(source, [profile])

    def test_ambiguous_firmware_is_rejected(self):
        source = 'Method (GBMD, 0) {}'
        profile = {'required_patterns': ['GBMD'], 'reviewed_dsdt_hashes': [support.normalized_hash(source)]}
        with self.assertRaises(ValueError):
            support.match_profile(source, [profile, profile])

    def test_shipped_bridge_refuses_unvalidated_writes(self):
        # Shipped profiles intentionally lack reviewed bridge hashes (fail-closed).
        self.assertEqual(support.profiles(), [])

        complete = json.loads((ROOT / 'HardwareProfiles/legion7-16achg6.json').read_text(encoding='utf-8'))
        fixture = copy.deepcopy(complete)
        synthetic_source = 'Method (GBMD, 0, NotSerialized) { Return (Zero) }'
        fixture['required_patterns'] = [r'Method \(GBMD, 0']
        fixture['reviewed_dsdt_hashes'] = [support.normalized_hash(synthetic_source)]
        fixture['verified_writes'] = 0

        telemetry = json.loads((ROOT / 'HardwareProfiles/ideapad-gaming3-gen5.json').read_text(encoding='utf-8'))

        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = pathlib.Path(tmp)
            hp_dir = tmp_root / 'HardwareProfiles'
            hp_dir.mkdir(parents=True)
            shutil.copy(ROOT / 'HardwareProfiles/SSDT-ReYoga.template.dsl', hp_dir / 'SSDT-ReYoga.template.dsl')
            (hp_dir / 'legion-fixture.json').write_text(json.dumps(fixture), encoding='utf-8')
            (hp_dir / 'telemetry-only.json').write_text(json.dumps(telemetry), encoding='utf-8')

            with patch.object(support, 'ROOT', tmp_root):
                candidates = support.profiles()
                self.assertEqual(len(candidates), 1)
                self.assertEqual(candidates[0]['id'], fixture['id'])
                self.assertEqual(support.match_profile(synthetic_source, candidates), fixture)

                source = support.render(candidates[0])
                self.assertNotIn('{{', source)
                self.assertEqual(candidates[0].get('verified_writes', 0), 0)
                self.assertIn('Method (RYVW, 0, Serialized) { Return (0) }', source)

                # Defaulting without verified_writes also fails closed.
                fixture_default = copy.deepcopy(fixture)
                fixture_default.pop('verified_writes', None)
                self.assertIn('Method (RYVW, 0, Serialized) { Return (0) }', support.render(fixture_default))

                ryfs = re.search(r'Method\s*\(RYFS,\s*2,\s*Serialized\)\s*\{(.*?)\s*Method\s*\(RYFA', source, re.DOTALL)
                self.assertIsNotNone(ryfs)
                body = ryfs.group(1)
                gate = 'If (!RYVW ()) { Return (One) }'
                gate_pos = body.find(gate)
                self.assertNotEqual(gate_pos, -1)
                for unsafe in ('RYB0 =', 'RYB1 =', 'RYC0 =', 'RYC1 =', 'RYRC ()', 'RYA0 = One', 'RYA1 = One'):
                    write_pos = body.find(unsafe)
                    self.assertNotEqual(write_pos, -1)
                    self.assertLess(gate_pos, write_pos)

    def test_unknown_device_and_bad_compiler_still_export_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            # Minimal checksum-valid DSDT with a firmware identity that is not supported.
            table = bytearray(36)
            table[:4] = b'DSDT'; table[4:8] = (36).to_bytes(4, 'little')
            table[8] = 2; table[9] = (-sum(table)) % 256
            input_file = root / 'DSDT.aml'; input_file.write_bytes(table)
            output = root / 'report'
            result = subprocess.run([sys.executable, str(ROOT / 'Scripts/hardware_support.py'),
                                     '--acpi', str(input_file), '--output', str(output),
                                     '--iasl', str(root / 'missing-iasl'), '--offline'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 1, result.stderr)
            report = json.loads((output / 'report.json').read_text(encoding='utf-8'))
            self.assertEqual(report['generation']['status'], 'unmatched')
            self.assertEqual(report['acpi'][0]['sha256'], hashlib.sha256(table).hexdigest())
            self.assertTrue(report['errors'])
            self.assertTrue(output.with_suffix('.zip').is_file())
            self.assertFalse(list(output.glob('SSDT-*.dsl')))


    def test_fingerprint_preserves_quoted_data(self):
        self.assertNotEqual(support.normalized_hash('Name (X, "a b")'), support.normalized_hash('Name (X, "ab")'))
        self.assertEqual(support.normalized_hash('Name (X, "a // b") /* ignored */'), support.normalized_hash('Name(X,"a // b")'))

if __name__ == '__main__':
    unittest.main()
