import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location('check_format', pathlib.Path(__file__).resolve().parents[1] / 'Scripts/check_format.py')
formatter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(formatter)


class FormatTests(unittest.TestCase):
    def test_clean_utf8_and_empty_files(self):
        self.assertEqual(formatter.violations('Dữ liệu\n'.encode()), [])
        self.assertEqual(formatter.violations(b''), [])

    def test_each_shared_rule_has_a_diagnostic(self):
        self.assertEqual(formatter.violations(b'\xff'), ['not valid UTF-8'])
        self.assertIn('use LF line endings', formatter.violations(b'x\r\n'))
        self.assertIn('missing final newline', formatter.violations(b'x'))
        self.assertIn('2: trailing whitespace', formatter.violations(b'x\ny \t\n'))


if __name__ == '__main__':
    unittest.main()
