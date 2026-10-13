"""Verify EC transaction boundaries without accessing hardware."""
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ec_reader', pathlib.Path(__file__).resolve().parents[1] / 'Scripts/ec_reader.py')
ec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ec)


class ECReaderTests(unittest.TestCase):
    def test_read_sends_only_read_command_and_address(self):
        statuses = iter([0, 0, 1])
        writes = []
        def read(port):
            return next(statuses) if port == 0x66 else 0xA5
        self.assertEqual(ec.read_byte(read, lambda *args: writes.append(args), 0x37), 0xA5)
        self.assertEqual(writes, [(0x66, 0x80), (0x62, 0x37)])

    def test_pending_response_is_not_consumed(self):
        writes = []
        with self.assertRaises(TimeoutError):
            ec.read_byte(lambda _: 1, lambda *args: writes.append(args), 0, timeout=0.002)
        self.assertEqual(writes, [])

    def test_invalid_offset_cannot_reach_ports(self):
        with self.assertRaises(ValueError):
            ec.read_byte(lambda _: self.fail(), lambda *_: self.fail(), 256)

    def test_failed_byte_is_null_and_scan_stops(self):
        class Backend:
            def __init__(self, _): self.closed = False
            def read_port(self, _): return 0
            def write_port(self, *_): pass
            def close(self): self.closed = True
        with tempfile.TemporaryDirectory() as directory, patch.object(ec.platform, 'system', return_value='Windows'), \
             patch.object(ec, 'module_binary', return_value=b'module'), patch.object(ec, 'PawnEC', Backend), \
             patch.object(ec, 'read_byte', side_effect=[0, TimeoutError('busy')]) as read:
            result = ec.collect(pathlib.Path(directory), 'PNP0C09 0x62 0x66', True)
            self.assertEqual(result['status'], 'partial')
            self.assertEqual(result['controllers'][0]['bytes'][:3], [0, None, None])
            self.assertEqual(read.call_count, 2)
            self.assertFalse(list(pathlib.Path(directory).glob('*.bin')))
