import tempfile
import pathlib
import unittest
from unittest.mock import patch

try:
    from . import source_tools
except ImportError:
    import source_tools


class SourceToolsTests(unittest.TestCase):
    def test_definition_keeps_nested_blocks_and_ignores_quoted_braces(self):
        body = 'bool Device::read()\n{ if (ready) { log("}"); /* } */ } // }\n return true; }'
        self.assertEqual(source_tools.function(body + '\nvoid next() {}', 'bool Device::read('), body)
        self.assertEqual(source_tools.function(body.replace('bool ', 'bool\n'), 'bool Device::read('), body.replace('bool ', 'bool\n'))

    def test_missing_or_incomplete_definition_fails_explicitly(self):
        for source in ['', 'void run() { if (true) { }']:
            with self.assertRaises(ValueError):
                source_tools.function(source, 'void run(')

    def test_discovery_includes_nested_sources_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'nested').mkdir()
            (root / 'nested/View.swift').write_text('nested', encoding='utf-8')
            with patch.object(source_tools, 'ROOT', root):
                self.assertEqual(source_tools.read_sources('**/*.swift', 'nested/*.swift'), 'nested')


if __name__ == '__main__':
    unittest.main()
