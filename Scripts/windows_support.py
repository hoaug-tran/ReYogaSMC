"""Windows inventory and registry ACPI collection; no driver installation."""
import hashlib
import json
import pathlib
import re
import subprocess


def table_valid(data):
    return len(data) >= 36 and data[:4] in (b'DSDT', b'SSDT') and int.from_bytes(data[4:8], 'little') == len(data) and sum(data) % 256 == 0


def registry_tables(directory):
    import winreg
    files = []; seen = set(); sources = []; errors = []
    def walk(key, names, depth=0):
        if depth > 12:
            return
        try:
            value, kind = winreg.QueryValueEx(key, '00000000')
            if kind == winreg.REG_BINARY:
                data = bytes(value)
                if table_valid(data):
                    digest = hashlib.sha256(data).hexdigest()
                    if digest not in seen:
                        seen.add(digest)
                        tag = re.sub('[^A-Za-z0-9_-]', '_', names[0] if names else 'root')[:24]
                        path = directory / (data[:4].decode() + '-' + tag + '-' + digest[:12] + '.aml')
                        path.write_bytes(data); files.append(path)
                        sources.append({'file': path.name, 'registry_key': '/'.join(names), 'sha256': digest})
        except OSError:
            pass
        index = 0
        while True:
            try:
                name = winreg.EnumKey(key, index)
            except OSError:
                break
            index += 1
            try:
                with winreg.OpenKey(key, name) as child:
                    walk(child, names + [name], depth + 1)
            except OSError as error:
                errors.append({'key': '/'.join(names + [name]), 'reason': str(error)})
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'HARDWARE\ACPI') as key:
            walk(key, [])
    except OSError as error:
        errors.append({'key': 'HARDWARE/ACPI', 'reason': str(error)})
    (directory / 'windows-table-sources.json').write_text(json.dumps({'tables': sources, 'errors': errors}, indent=2), encoding='utf-8')
    return files


def inventory(live=False):
    script = pathlib.Path(__file__).with_name('windows_inventory.ps1')
    command = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(script), '-ProbeManifest', str(script.with_name('windows_probes.json'))]
    if live:
        command.append('-Live')
    try:
        result = subprocess.run(command, capture_output=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'status': 'failed', 'reason': str(error)}
    try:
        value = json.loads(result.stdout.decode('utf-8-sig'))
    except (UnicodeError, ValueError):
        return {'status': 'failed', 'exit_code': result.returncode, 'reason': result.stderr.decode(errors='replace')[-4000:] or 'PowerShell returned no JSON report'}
    value['process_status'] = result.returncode
    return value
