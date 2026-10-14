"""Check Windows export evidence without a firmware provider."""
import importlib.util
import json
import pathlib
import unittest
from unittest.mock import patch
import subprocess
import platform

root = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('windows_support', root / 'Scripts/windows_support.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class WindowsSupportTests(unittest.TestCase):
    def table(self, signature=b'DSDT'):
        data=bytearray(36);data[:4]=signature;data[4:8]=(36).to_bytes(4,'little');data[9]=(-sum(data))%256
        return bytes(data)
    def test_only_valid_support_tables_are_accepted(self):
        self.assertTrue(module.table_valid(self.table()))
        self.assertFalse(module.table_valid(self.table(b'MSDM')))
        damaged=bytearray(self.table());damaged[-1]^=1
        self.assertFalse(module.table_valid(bytes(damaged)))
        self.assertFalse(module.table_valid(self.table()[:-1]))
    def test_powershell_failure_is_not_an_empty_success(self):
        with patch.object(module.subprocess,'run',return_value=subprocess.CompletedProcess([],1,b'',b'Provider denied')):
            value=module.inventory(True)
        self.assertEqual(value['status'],'failed');self.assertIn('denied',value['reason'])
    def test_all_probe_outputs_and_errors_survive(self):
        report={'probes':[{'status':'collected','result':{'Data':3,'ReturnValue':0}},{'status':'failed','reason':'Not supported'}]}
        with patch.object(module.subprocess,'run',return_value=subprocess.CompletedProcess([],0,json.dumps(report).encode(),b'')):
            value=module.inventory(True)
        self.assertEqual(value['probes'],report['probes'])
    def test_probe_manifest_contains_no_write_methods(self):
        data=json.loads((root/'Scripts/windows_probes.json').read_text())
        for probe in data['probes']:
            self.assertRegex(probe['method'],r'^(Get|Is|Fan_Get|CPU_Get)')
            self.assertEqual(probe['namespace'],'root/wmi')

    @unittest.skipUnless(platform.system() == 'Windows', 'PowerShell parser is available on Windows')
    def test_powershell_script_parses(self):
        path=str(root / 'Scripts/windows_inventory.ps1').replace("'", "''")
        code="$tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('"+path+"',[ref]$tokens,[ref]$errors);if($errors.Count){$errors | ForEach-Object {$_.Message};exit 1}"
        result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',code],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
