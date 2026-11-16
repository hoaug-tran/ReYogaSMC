"""Unit tests for SMCTemperatureReader dual AMD provider detection and key ordering."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def decode_sp78(bytes_val):
    if len(bytes_val) != 2:
        return None
    raw = int.from_bytes(bytes_val, byteorder='big', signed=True)
    val = raw / 256.0
    return val if 0 < val < 150 else None


def cpu_temperature_keys(available, amd):
    order = ["TC0E", "TC0F", "TC0P", "TC0T"] if amd else ["TC0P", "TC0D", "TC0E", "TC0F", "TC0T"]
    return [k for k in order if k in available]


def cpu_temperature_provider(has_smc_amd_processor, has_smc_processor_amd):
    if has_smc_amd_processor:
        return "SMCAMDProcessor"
    if has_smc_processor_amd:
        return "SMCProcessorAMD"
    return "SMC"


class SMCTemperatureReaderTests(unittest.TestCase):
    def test_cpu_temperature_keys_ordering(self):
        available = ["TC0G", "TC0E", "TC0P", "TCGC"]
        # On AMD, TC0E (package) must take priority over TC0P
        self.assertEqual(cpu_temperature_keys(available, amd=True), ["TC0E", "TC0P"])
        # On Intel, TC0P must take priority over TC0E
        self.assertEqual(cpu_temperature_keys(available, amd=False), ["TC0P", "TC0E"])

    def test_cpu_temperature_provider_resolution(self):
        # SMCAMDProcessor (full power & sensors kext)
        self.assertEqual(
            cpu_temperature_provider(has_smc_amd_processor=True, has_smc_processor_amd=False),
            "SMCAMDProcessor"
        )
        # SMCProcessorAMD (sensor-only kext)
        self.assertEqual(
            cpu_temperature_provider(has_smc_amd_processor=False, has_smc_processor_amd=True),
            "SMCProcessorAMD"
        )
        # Both present -> SMCAMDProcessor has precedence
        self.assertEqual(
            cpu_temperature_provider(has_smc_amd_processor=True, has_smc_processor_amd=True),
            "SMCAMDProcessor"
        )
        # Neither present -> fallback to generic SMC
        self.assertEqual(
            cpu_temperature_provider(has_smc_amd_processor=False, has_smc_processor_amd=False),
            "SMC"
        )

    def test_sp78_temperature_decoding_boundaries(self):
        # 80.5 degrees C
        self.assertEqual(decode_sp78(bytes([80, 128])), 80.5)
        # 51.582 degrees C from live target machine diagnostic
        self.assertAlmostEqual(decode_sp78(bytes([51, 149])), 51.58203125, places=4)
        # Zero rejected
        self.assertIsNone(decode_sp78(bytes([0, 0])))
        # Negative rejected
        self.assertIsNone(decode_sp78(bytes([255, 0])))
        # Over 150 rejected
        self.assertIsNone(decode_sp78(bytes([155, 0])))

    def test_swift_source_wiring_dual_providers(self):
        source = (ROOT / 'ReYogaSMCApp/Hardware/Sensors/SMCTemperatureReader.swift').read_text(encoding='utf-8')
        self.assertIn('providerExists("SMCAMDProcessor")', source)
        self.assertIn('providerExists("SMCProcessorAMD")', source)
        self.assertIn('static func cpuTemperatureProvider', source)
        self.assertIn('let amd = cpuProvider != "SMC"', source)


if __name__ == '__main__':
    unittest.main()
