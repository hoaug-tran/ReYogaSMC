#!/usr/bin/env python3
"""ReYoga hardware discovery and ACPI export. No EC writes or installation."""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = pathlib.Path.home() / '.cache' / 'reyoga' / 'acpica'


def profiles():
    return [item for p in sorted((ROOT / 'HardwareProfiles').glob('*.json'))
            if 'required_patterns' in (item := json.loads(p.read_text()))]


def normalized_hash(source):
    normalized = re.sub(r'\s+', '', re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S))
    return hashlib.sha256(normalized.encode()).hexdigest()


def match_profile(source, candidates, aml_hashes=()):
    digest = normalized_hash(source)
    matches = [p for p in candidates
               if (digest in p.get('reviewed_dsdt_hashes', []) or
                   any(h in p.get('reviewed_aml_hashes', []) for h in aml_hashes))
               and all(re.search(pattern, source) for pattern in p['required_patterns'])]
    if len(matches) != 1:
        raise ValueError('No unique reviewed firmware profile matched. The report is ready for a device-support issue.')
    return matches[0]


def render(profile):
    values = dict(profile, profile_name=profile['name'], **profile['offsets'])
    values['verified_writes'] = 1 if profile.get('verified_writes') == 1 else 0
    source = (ROOT / 'HardwareProfiles/SSDT-ReYoga.template.dsl').read_text()
    for key, value in values.items():
        source = source.replace('{{' + key + '}}', str(value))
    if '{{' in source:
        raise ValueError('Profile template has unresolved fields')
    return source


def run(command, cwd=None):
    result = subprocess.run([str(x) for x in command], cwd=cwd, capture_output=True,
                            timeout=180, check=False)
    return {'command': [str(x) for x in command], 'status': result.returncode,
            'stdout': result.stdout.decode('utf-8', errors='replace'),
            'stderr': result.stderr.decode('utf-8', errors='replace')}


def download(item, destination):
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == item['sha256']:
        return
    with urllib.request.urlopen(item['url'], timeout=60) as response:
        data = response.read(32 * 1024 * 1024 + 1)
    if len(data) > 32 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != item['sha256']:
        raise ValueError('ACPICA download failed checksum or size validation')
    destination.write_bytes(data)


def compiler(offline=False):
    existing = shutil.which('iasl')
    if existing:
        return pathlib.Path(existing)
    lock = json.loads((ROOT / 'Scripts/acpica.json').read_text())
    directory = CACHE / lock['release'] / platform.system()
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / ('iasl.exe' if platform.system() == 'Windows' else 'iasl')
    # Cached downloaded executables are checked on every use.
    if platform.system() == 'Windows':
        item = lock['Windows']['iasl']
        if offline and not executable.exists():
            raise ValueError('iasl unavailable in offline mode')
        if offline:
            if hashlib.sha256(executable.read_bytes()).hexdigest() != item['sha256']:
                raise ValueError('Cached iasl checksum mismatch')
        else:
            download(item, executable)
        return executable
    if executable.exists():
        return executable
    if offline:
        raise ValueError('iasl unavailable in offline mode')
    if not shutil.which('make') or not (shutil.which('cc') or shutil.which('gcc')):
        raise ValueError('Install the system C build tools once, or put iasl on PATH. The report can still be exported.')
    archive = directory / 'source.tar.gz'
    download(lock['source'], archive)
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            target = (directory / member.name).resolve()
            if not target.is_relative_to(directory.resolve()) or not (member.isfile() or member.isdir()):
                raise ValueError('Unsafe ACPICA archive entry')
        bundle.extractall(directory)
    sources = list(directory.glob('acpica-*/generate/unix'))
    if len(sources) != 1:
        raise ValueError('ACPICA source layout changed')
    result = run(['make', 'iasl', '-j2'], cwd=sources[0])
    (directory / 'build.log').write_text(result['stdout'] + result['stderr'])
    if result['status']:
        raise ValueError('ACPICA build failed; see ' + str(directory / 'build.log'))
    shutil.copy2(sources[0] / 'bin/iasl', executable)
    return executable


def windows_tables(directory):
    import windows_support
    registry = windows_support.registry_tables(directory)
    # GetSystemFirmwareTable reads firmware through Windows; no physical-memory driver.
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    enum = kernel.EnumSystemFirmwareTables
    get = kernel.GetSystemFirmwareTable
    enum.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
    get.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
    enum.restype = get.restype = ctypes.c_uint32
    provider = int.from_bytes(b'ACPI', 'big')
    size = enum(provider, None, 0)
    if not size or size > 1024 * 1024 or size % 4:
        if registry:
            return registry
        raise OSError('Windows could not enumerate ACPI tables: ' + str(ctypes.get_last_error()))
    buffer = ctypes.create_string_buffer(size)
    if enum(provider, buffer, size) != size:
        raise OSError('ACPI table inventory changed; retry')
    files = list(registry)
    seen = set()
    hashes = {hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    for offset in range(0, size, 4):
        identifier = int.from_bytes(buffer.raw[offset:offset + 4], 'little')
        if identifier in seen:
            continue
        seen.add(identifier)
        length = get(provider, identifier, None, 0)
        if not 36 <= length <= 16 * 1024 * 1024:
            continue
        table = ctypes.create_string_buffer(length)
        if get(provider, identifier, table, length) != length:
            continue
        signature = table.raw[:4].decode('ascii', errors='replace')
        if signature not in ('DSDT', 'SSDT'):
            continue
        digest = hashlib.sha256(table.raw).hexdigest()
        if digest in hashes:
            continue
        hashes.add(digest)
        path = directory / f'{signature}-{len(files):02d}.aml'
        path.write_bytes(table.raw)
        files.append(path)
    return files


def inventory(windows_live=False):
    report = {'platform': platform.system(), 'release': platform.release(), 'probes': {}, 'services': []}
    if platform.system() == 'Windows':
        import windows_support
        report['windows'] = windows_support.inventory(live=windows_live)
    elif platform.system() == 'Darwin':
        report['probes']['os'] = run(['sw_vers'])
        for name in ['IdeaVPC', 'ThinkVPC', 'YogaHIDD', 'DYVPC', 'IOHIDDevice']:
            raw = subprocess.run(['ioreg', '-a', '-r', '-c', name], capture_output=True, timeout=30)
            if raw.returncode or not raw.stdout.strip():
                report['probes'][name] = {'status': raw.returncode, 'reason': raw.stderr.decode(errors='replace')}
                continue
            entries = plistlib.loads(raw.stdout)
            keys = ['VersionInfo', 'ControlProtocolVersion', 'FeatureStatus', 'SensorStatus',
                    'SensorSampleSequence', 'LastControlResult', 'ACPIBridgeVersion', 'ACPIProfileID',
                    'FanWritesValidated', 'HardwareProfile', 'HardwareProfileName', 'PowerLimitRanges', 'YLogoRawState', 'YLogoRawBrightness', 'PortLightingRawState', 'PortLightingRawBrightness', 'FanFullSpeedRaw', 'BatteryModeRaw', 'ConservationMode', 'RapidChargeMode', 'Fan1RPM', 'Fan2RPM',
                    'CPUTemp', 'GPUTemp', 'VendorID', 'ProductID', 'Product', 'Transport', 'MaxFeatureReportSize']
            report['services'].extend({'class': name, 'properties': {k: e[k] for k in keys if k in e}}
                                      for e in entries)
    return report


def constant(text):
    text = text.strip()
    if text in ('Zero', 'One'):
        return 0 if text == 'Zero' else 1
    if re.fullmatch(r'0x[0-9A-Fa-f]+|[0-9]+', text):
        return int(text, 16 if text.startswith('0x') else 10)
    return None


def split_terms(text):
    terms, start, depth = [], 0, 0
    for index, char in enumerate(text):
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
        elif char == ',' and depth == 0:
            terms.append(text[start:index].strip()); start = index + 1
    terms.append(text[start:].strip())
    return terms


def scan_fields(clean, regions):
    fields = []
    for block in re.finditer(r'(?<![\w])Field\s*\(([^{}]+?)\)\s*\{([^}]+)\}', clean):
        region = block.group(1).split(',')[0].strip()
        candidates = [r for r in regions if r['name'] == region]
        base = constant(candidates[0]['base_expression']) if len(candidates) == 1 and candidates[0]['space'] == 'SystemMemory' else None
        bit_offset = 0
        terms = split_terms(block.group(2))
        index = 0
        while index < len(terms):
            term = terms[index]
            offset = re.fullmatch(r'Offset\s*\(([^)]+)\)', term)
            if offset:
                value = constant(offset.group(1))
                bit_offset = value * 8 if value is not None else None
                index += 1; continue
            if term.startswith(('AccessAs', 'Connection', 'ExtendedAccess')):
                index += 1; continue
            if index + 1 >= len(terms):
                break
            width = constant(terms[index + 1])
            if re.fullmatch(r'[A-Z_][A-Z0-9_]{0,3}', term):
                item = {'name': term, 'region': region, 'bit_offset': bit_offset, 'bit_width': width,
                        'declaration_line': clean[:block.start()].count('\n') + 1}
                if bit_offset is not None:
                    item['byte_offset'] = bit_offset // 8
                    item['bit_in_byte'] = bit_offset % 8
                    if base is not None:
                        item['declared_memory_address'] = hex(base + bit_offset // 8)
                fields.append(item)
            # Dynamic lengths stop relative offset inference until a literal Offset.
            bit_offset = bit_offset + width if bit_offset is not None and width is not None else None
            index += 2
    return fields


def decode_wdg(buffers):
    entries = []
    for index, text in enumerate(buffers):
        tokens = [x.strip() for x in text.split(',') if x.strip()]
        values = [constant(x) for x in tokens]
        if any(x is None or x > 255 for x in values) or len(values) % 20:
            entries.append({'buffer': index, 'reason': 'Nonliteral or incomplete WDG buffer; inspect source'})
            continue
        data = bytes(values)
        for offset in range(0, len(data), 20):
            row = data[offset:offset + 20]
            flags = row[19]
            entries.append({'buffer': index, 'guid': str(uuid.UUID(bytes_le=row[:16])),
                            'object_id_hex': row[16:18].hex(),
                            'object_id': row[16:18].decode('ascii', errors='replace') if not flags & 8 else None,
                            'instance_count': row[18], 'flags': flags,
                            'method': bool(flags & 2), 'event': bool(flags & 8)})
    return entries


def scan(source):
    clean = re.sub(r'/\*.*?\*/|//[^\n]*', lambda match: re.sub(r'[^\n]', ' ', match.group()), source, flags=re.S)
    regions = [{'name': m[0], 'space': m[1], 'base_expression': m[2].strip(), 'length_expression': m[3].strip()}
               for m in re.findall(r'OperationRegion\s*\(\s*([\\\w.]+)\s*,\s*(\w+)\s*,\s*([^,\n]+),\s*([^\)\n]+)\)', clean)]
    wdg = re.findall(r'Name\s*\(\s*_WDG\s*,\s*Buffer[^\{]*\{([^}]+)\}', clean)
    return {
        'methods': [{'name': m[0], 'arguments': int(m[1])} for m in
                    re.findall(r'Method\s*\(\s*([\\\w.]+)\s*,\s*([0-7])', clean)],
        'regions': regions, 'fields': scan_fields(clean, regions), 'wmi_guids': decode_wdg(wdg),
        'device_ids': sorted(set(re.findall(r'(?:PNP|LEN|VPC|ITE)[0-9A-Fa-f]{4}', clean))),
        'wmi_buffers': wdg,
        'field_blocks': re.findall(r'Field\s*\([^\{]+\{[^}]+\}', clean),
        'limits': 'Static declarations only. Namespace aliases, banked/indexed fields, dynamic expressions and units require review. Declared addresses are not control instructions.'
    }


def table_signature(path):
    with path.open('rb') as stream:
        header = stream.read(8192)
    if path.suffix.lower() == '.dsl':
        text = header.decode('utf-8', errors='replace')
        match = re.search(r'DefinitionBlock\s*\(\s*"[^"]*"\s*,\s*"(DSDT|SSDT)"', text)
        return match.group(1) if match else None
    return header[:4].decode('ascii', errors='replace')


def main():
    import ec_reader
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--acpi', type=pathlib.Path, help='Directory of AML/DAT/DSL tables, or a single table')
    parser.add_argument('--dsdt', type=pathlib.Path, help='Alias for a DSDT input')
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('ReYoga-report-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')), help='New export directory')
    parser.add_argument('--model', default='', help='Model label for generated SSDT filename')
    parser.add_argument('--compile', action='store_true', help='Request compiler setup even for source input')
    parser.add_argument('--source-only', action='store_true', help='Export a matched bridge without compiling it')
    parser.add_argument('--offline', action='store_true', help='Disable dependency downloads')
    parser.add_argument('--iasl', type=pathlib.Path, help='Use a specific iasl executable')
    parser.add_argument('--ec-read', action='store_true', help='Collect a live unbanked EC snapshot on Windows/Linux')
    parser.add_argument('--windows-live', action='store_true', help='Run reviewed Windows getter probes; no setters')
    parser.add_argument('--windows-report', type=pathlib.Path, help='Attach a previously collected Windows JSON report')
    args = parser.parse_args()
    if not (args.acpi or args.dsdt) and platform.system() == 'Darwin' and sys.stdin.isatty():
        path = input('ACPI dump directory or DSDT path (blank for runtime report only): ').strip().strip('"\'')
        if path:
            args.acpi = pathlib.Path(path).expanduser()
    output = args.output.resolve()
    # Keep exports isolated so source files and prior reports cannot be overwritten.
    if pathlib.Path(str(output) + '.zip').exists():
        raise ValueError('Export ZIP already exists; choose a new output directory')
    output.mkdir(parents=True, exist_ok=False)
    tables = output / 'tables'; tables.mkdir()
    report = {'schema_version': 1, 'tool': 'ReYoga', 'errors': [], 'excluded_tables': [], 'acpi': [], 'generation': {'status': 'unmatched'}}
    try:
        report['inventory'] = inventory(args.windows_live)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report['errors'].append({'stage': 'inventory', 'reason': str(error)})
    if args.windows_report:
        try:
            imported = json.loads(args.windows_report.read_text(encoding='utf-8-sig'))
            report['windows_evidence'] = {'source_sha256': hashlib.sha256(args.windows_report.read_bytes()).hexdigest(),
                'data': imported, 'live_wmi_present': bool(imported.get('live_wmi_results') or imported.get('probes')),
                'live_ec_present': bool(imported.get('live_ec_dump'))}
        except (OSError, ValueError) as error:
            report['errors'].append({'stage': 'windows_report', 'reason': str(error)})
    inputs = []
    input_path = args.acpi or args.dsdt
    if input_path:
        try:
            inputs = sorted(input_path.iterdir()) if input_path.is_dir() else [input_path]
            inputs = [p for p in inputs if p.suffix.lower() in ('.aml', '.dat', '.dsl')]
            for index, path in enumerate(inputs):
                try:
                    if table_signature(path) not in ('DSDT', 'SSDT'):
                        report['excluded_tables'].append({'file': path.name, 'reason': 'Only DSDT and SSDT are needed for this workflow'})
                        continue
                    shutil.copy2(path, tables / f'{index:03d}-{path.name}')
                except OSError as error:
                    report['errors'].append({'stage': 'input', 'file': path.name, 'reason': str(error)})
        except OSError as error:
            report['errors'].append({'stage': 'input', 'reason': str(error)})
        inputs = sorted(tables.iterdir())
    elif platform.system() == 'Windows':
        try:
            inputs = windows_tables(tables)
            report['windows_acpi_limit'] = 'Registry tables supplement the firmware API, which returns only the first table for duplicate SSDT signatures. A complete dump is still needed if tables are missing.'
        except OSError as error:
            report['errors'].append({'stage': 'firmware_dump', 'reason': str(error)})
    elif platform.system() == 'Linux':
        for path in sorted(pathlib.Path('/sys/firmware/acpi/tables').glob('*')):
            if path.name.startswith(('DSDT', 'SSDT')) and path.is_file():
                try:
                    target = tables / (path.name + '.aml'); target.write_bytes(path.read_bytes()); inputs.append(target)
                except OSError as error:
                    report['errors'].append({'stage': 'firmware_dump', 'reason': str(error)})
    binaries = [p for p in inputs if p.suffix.lower() != '.dsl']
    iasl = None
    if binaries or args.compile:
        try:
            iasl = args.iasl.resolve() if args.iasl else compiler(args.offline)
            report['compiler'] = run([iasl, '-v'])
            if binaries:
                result = run([iasl, '-da', *binaries], cwd=tables)
                report['disassembly'] = result
                if result['status']:
                    fallback = [run([iasl, '-d', path], cwd=tables) for path in binaries]
                    report['disassembly']['individual_tables'] = fallback
                    report['disassembly']['cross_table_resolution'] = 'failed; individual disassembly does not resolve every external reference'
                    if any(item['status'] for item in fallback):
                        report['errors'].append({'stage': 'disassembly', 'reason': 'Some tables failed individual disassembly; inspect the retained compiler results'})
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            report['errors'].append({'stage': 'compiler', 'reason': str(error)})
    aml_hashes = []
    for path in binaries:
        data = path.read_bytes()
        valid = len(data) >= 36 and int.from_bytes(data[4:8], 'little') == len(data) and sum(data) % 256 == 0
        item = {'file': path.name, 'sha256': hashlib.sha256(data).hexdigest(), 'valid_header_checksum': valid}
        if valid and data[:4] == b'DSDT':
            aml_hashes.append(item['sha256'])
        report['acpi'].append(item)
    sources = sorted(p for p in tables.iterdir() if p.suffix.lower() == '.dsl')
    for path in sources:
        source = path.read_text(errors='replace')
        report['acpi'].append({'file': path.name, 'normalized_sha256': normalized_hash(source), 'declarations': scan(source)})
    combined = '\n'.join(p.read_text(errors='replace') for p in sources)
    try:
        profile = match_profile(combined, profiles(), aml_hashes)
        # Hashes of individual DSL inputs must also work with a full table bundle.
    except ValueError:
        profile = None
        for path in sources:
            try:
                profile = match_profile(path.read_text(errors='replace'), profiles(), aml_hashes)
                break
            except ValueError:
                pass
    if profile:
        label = re.sub(r'[^A-Za-z0-9]+', '-', args.model or profile['id']).strip('-')[:32] or 'device'
        bridge = output / f'SSDT-ReYoga-{label}.dsl'
        bridge.write_text(render(profile))
        report['generation'] = {'status': 'generated', 'profile': profile['id'], 'source': bridge.name,
                                'validation': profile['validation'], 'fan_writes': profile.get('verified_writes') == 1}
        if not args.source_only and not iasl:
            try:
                iasl = args.iasl.resolve() if args.iasl else compiler(args.offline)
                report['compiler'] = run([iasl, '-v'])
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                report['errors'].append({'stage': 'compiler', 'reason': str(error)})
        if not args.source_only and iasl:
            result = run([iasl, '-tc', bridge], cwd=output)
            report['generation']['compile'] = result
            if result['status']:
                report['errors'].append({'stage': 'compile', 'reason': 'Compilation failed; do not install the AML'})
    report['ec'] = ec_reader.collect(output, combined, args.ec_read, args.offline)
    if args.ec_read and report['ec']['status'] in ('unavailable', 'partial'):
        report['errors'].append({'stage': 'ec', 'reason': report['ec'].get('reason', 'Snapshot stopped after an EC transaction failure; inspect the per-byte failures')})
    report['coverage'] = {
        'table_count': len(inputs), 'source_count': len(sources),
        'profile_matched': profile is not None,
        'compiler_available': iasl is not None,
        'collected': ['ACPI source declarations', 'table fingerprints', 'OS inventory', 'available runtime capabilities', 'requested Windows getter results and EC snapshot status'],
        'requires_review': ['EC field meaning and units', 'WMI method payloads', 'USB HID protocol', 'hotkey mapping', 'fan-write safety'],
        'reason': 'ACPI does not describe every firmware interface. No register writes or firmware-method calls are performed. EC snapshots cover only the declared standard address space.'}
    (output / 'report.json').write_text(json.dumps(report, indent=2, default=str) + '\n')
    summary = '# ReYoga device support\n\n' + \
        'Generation: ' + report['generation']['status'] + '\n\n' + \
        'Attach report.json and the ACPI tables after checking them for private data.\n\n' + \
        '## Observed behavior\n\nModel / BIOS:\nmacOS / bootloader:\nFeature / expected / actual:\nSteps to reproduce:\nSleep and AC/battery behavior:\n\n' + \
        '## Review needed\n\n' + '\n'.join('* ' + x for x in report['coverage']['requires_review']) + '\n'
    (output / 'device-support.md').write_text(summary)
    shutil.make_archive(str(output), 'zip', root_dir=output)
    print('Report: ' + str(output / 'report.json'))
    print('Export: ' + str(output) + '.zip')
    if report['generation']['status'] == 'generated':
        print('Bridge: ' + report['generation']['source'])
        if report['generation'].get('compile', {}).get('status') == 0:
            print('AML compiled; review it before adding it to your bootloader.')
    for error in report['errors']:
        print(error['stage'] + ': ' + error['reason'], file=sys.stderr)
    if report['generation']['status'] == 'unmatched':
        print('Unknown firmware: export is ready; an SSDT needs a reviewed profile.')
    return 1 if report['errors'] else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('ReYoga: ' + str(error), file=sys.stderr)
        sys.exit(1)
