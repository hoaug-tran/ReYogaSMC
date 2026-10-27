"""Run production DYTC methods against the supplied machines' firmware rules."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class DYTCReplayTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++') or shutil.which('clang++'), 'C++ compiler required')
    def test_profile_selection_readback_and_recovery(self):
        production = (ROOT / 'ReYogaSMC/ReYogaVPC.cpp').read_text(encoding='utf-8')
        bodies = []
        for name in ('DYTCCommand', 'parseDYTC', 'updateDYTC', 'setThermalProfile', 'setDYTC'):
            start = production.index('bool ReYogaVPC::' + name + '(')
            end = production.index('\n}', start) + 2
            bodies.append(production[start:end])
        fixture = (ROOT / 'Tests/dytc_replay.cpp').read_text(encoding='utf-8')
        fixture = fixture.replace('// Production method bodies are inserted here by test_dytc_replay.py.', '\n'.join(bodies))
        header = (ROOT / 'ReYogaSMC/ReYogaVPC.hpp').read_text(encoding='utf-8')
        start = header.index('    bool supportsThermalProfiles()')
        helpers = header[start:header.index('\n\n', start)]
        fixture = fixture.replace('// Production thermal helpers are inserted here by test_dytc_replay.py.', helpers)
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            (folder / 'libkern').mkdir()
            (folder / 'libkern/OSTypes.h').write_text(
                'using UInt = unsigned; using UInt8 = unsigned char; using UInt16 = unsigned short; using UInt32 = unsigned;\n', encoding='utf-8')
            source = folder / 'replay.cpp'
            source.write_text(fixture, encoding='utf-8')
            executable = folder / 'dytc-replay.exe'
            abi = ['-mno-ms-bitfields'] if sys.platform == 'win32' else []
            sanitizers = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if sys.platform != 'win32' else []
            build = subprocess.run([shutil.which('g++') or shutil.which('clang++'), *abi, '-std=c++14', '-Wall', '-Wextra', '-Werror', '-Wno-missing-field-initializers',
                                    *sanitizers, '-I', str(folder), '-I', str(ROOT), str(source), '-o', str(executable)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            for case in ('x1-profiles', 'capability-recovery', 'balanced-no-reset', 'masked-readback', 't490-profiles', 'transport-recovery', 'invalid-input', 'csc-balance'):
                with self.subTest(case=case):
                    result = subprocess.run([str(executable), case], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
