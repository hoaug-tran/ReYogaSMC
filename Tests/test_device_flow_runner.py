"""Coverage reporting must fail closed when tools, tests or native gates are missing."""
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch
from Scripts import check_device_flows as runner


class DeviceFlowRunnerTests(unittest.TestCase):
    def test_missing_tools_are_incomplete_without_running_commands(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.shutil, 'which', return_value=None), \
             patch.object(runner.subprocess, 'run') as command:
            output = pathlib.Path(directory)
            self.assertEqual(runner.run(output), 2)
            report = json.loads((output / 'report.json').read_text(encoding='utf-8'))
            self.assertEqual(report['status'], 'incomplete')
            self.assertEqual(report['hardware'], 'not_run')
            self.assertIn('swiftc', report['missing'])
            command.assert_not_called()

    def test_area_without_tests_cannot_be_called_passed(self):
        self.assertEqual(runner.area_coverage([])['controls_readback_restore']['state'], 'not_run')

    def test_skipped_area_is_partial_and_failure_wins(self):
        rows = [{'module': 'test_device_flows', 'test': 'fixture', 'state': 'passed'},
                {'module': 'test_device_flows', 'test': 'flow', 'state': 'skipped'}]
        self.assertEqual(runner.area_coverage(rows)['controls_readback_restore']['state'], 'partial')
        rows.append({'module': 'test_control_request', 'test': 'envelope', 'state': 'failed'})
        self.assertEqual(runner.area_coverage(rows)['controls_readback_restore']['state'], 'failed')
