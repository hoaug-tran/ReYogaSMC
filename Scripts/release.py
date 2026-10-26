"""Plan versions, extract changelog notes and validate release packages."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = pathlib.Path('ReYogaSMC.xcodeproj/project.pbxproj')
CHANGELOG = pathlib.Path('Changelog.md')
METADATA = (PROJECT.as_posix(), CHANGELOG.as_posix())


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True, encoding='utf-8').strip()


def version_tuple(value):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value):
        raise ValueError('Expected a major.minor.patch version')
    return tuple(map(int, value.split('.')))


def project_version(text):
    values = set(re.findall(r'CURRENT_PROJECT_VERSION = ([0-9.]+);', text))
    if len(values) != 1:
        raise ValueError('Project configurations must use one version')
    value = values.pop()
    version_tuple(value)
    return value


def bump(version, messages):
    major, minor, patch = version_tuple(version)
    if any(re.search(r'^[a-z]+(?:\([^\n]+\))?!:|^BREAKING[ -]CHANGE:', message, re.M) for message in messages):
        return f'{major + 1}.0.0'
    if any(re.match(r'feat(?:\([^\n]+\))?:', message) for message in messages):
        return f'{major}.{minor + 1}.0'
    return f'{major}.{minor}.{patch + 1}'


def shipped(path):
    if path.endswith('.md'):
        return False
    if path.startswith(('ReYogaSMC/', 'ReYogaSMCApp/', 'ReYogaSMCUtils/', 'ReYogaSMCHelper/', 'HardwareProfiles/')):
        return True
    return path in ('en.lproj/Localizable.strings', 'vi.lproj/Localizable.strings',
                    'ReYoga.cmd', 'ReYoga.command', PROJECT.as_posix()) or (
        path.startswith('Scripts/') and pathlib.PurePosixPath(path).name not in ('release.py', 'generate_firmware_profiles.py'))


def section(text, heading):
    match = re.search(r'^## ' + re.escape(heading) + r'\s*\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    return match.group(1).strip() if match else ''


def prepare(changelog, version, messages):
    existing = section(changelog, version)
    pending = section(changelog, 'Unreleased')
    if existing:
        if pending:
            raise ValueError('Move pending changes to the versioned changelog section')
        return changelog, existing + '\n'
    notes = pending or '\n'.join('- ' + message.splitlines()[0] for message in messages)
    if not notes:
        raise ValueError('Release notes are empty')
    if pending:
        changelog = re.sub(r'^## Unreleased\s*$', '## ' + version, changelog, count=1, flags=re.M)
    else:
        changelog = changelog.replace('# Releases\n', '# Releases\n\n## ' + version + '\n\n' + notes + '\n', 1)
    if section(changelog, version) != notes:
        raise ValueError('Changelog section could not be created')
    return changelog, notes + '\n'


def plan():
    current = project_version((ROOT / PROJECT).read_text(encoding='utf-8'))
    tags = [tag for tag in git('tag', '--merged', 'HEAD').splitlines() if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag)]
    latest = max(tags, key=lambda tag: version_tuple(tag[1:])) if tags else None
    revision = git('rev-parse', 'HEAD')
    span = latest + '..HEAD' if latest else 'HEAD'
    paths = git('diff', '--name-only', latest, 'HEAD').splitlines() if latest else git('ls-files').splitlines()
    changed = any(shipped(path) for path in paths)
    source_paths = sorted({path for path in paths + git('ls-files').splitlines() if shipped(path)})
    messages = [message.strip() for message in git('log', '--format=%B%x00', span, '--', *source_paths).split('\x00') if message.strip()]
    version = current
    at_tag = latest is not None and git('rev-list', '-n', '1', latest) == revision
    if latest and changed:
        version = current if version_tuple(current) > version_tuple(latest[1:]) else bump(latest[1:], messages)
    return {'version': version, 'publish': changed or at_tag, 'revision': revision, 'messages': messages}


def package_manifest(version):
    version_tuple(version)
    executables = {
        'ReYogaSMC': ['ReYogaSMC.kext/Contents/MacOS/ReYogaSMC', 'ReYogaSMC.kext/Contents/Info.plist'],
        'ReYogaSMC-App': ['ReYogaSMC.app/Contents/MacOS/ReYogaSMC',
                        'ReYogaSMC.app/Contents/Library/LoginItems/ReYogaSMCHelper.app/Contents/MacOS/ReYogaSMCHelper',
                        'ReYogaSMC.app/Contents/Info.plist',
                        'ReYogaSMC.app/Contents/Library/LoginItems/ReYogaSMCHelper.app/Contents/Info.plist'],
    }
    return {f'{mode}/{product}-{version}-{mode.upper()}.zip': members
            for mode in ('Debug', 'Release') for product, members in executables.items()}


def verify_assets(folder, version=None):
    folder = pathlib.Path(folder)
    version = version or os.environ.get('BUILD_VERSION') or project_version((ROOT / PROJECT).read_text(encoding='utf-8'))
    manifest = package_manifest(version)
    expected = set(manifest)
    actual = {path.relative_to(folder).as_posix() for path in folder.rglob('*.zip')}
    if actual != expected:
        raise ValueError(f'Package mismatch; missing={sorted(expected - actual)}, extra={sorted(actual - expected)}')
    lines = []
    for name, required in sorted(manifest.items()):
        path = folder / name
        if path.stat().st_size == 0:
            raise ValueError('Empty package: ' + name)
        with zipfile.ZipFile(path) as archive:
            for member in required:
                if member not in archive.namelist() or archive.getinfo(member).file_size == 0:
                    raise ValueError('Missing packaged file: ' + member)
            for member in required:
                if member.endswith('/Info.plist'):
                    metadata = plistlib.loads(archive.read(member))
                    if metadata.get('CFBundleShortVersionString') != version:
                        raise ValueError('Packaged version mismatch: ' + member)
            if archive.testzip() is not None:
                raise ValueError('Corrupt ZIP: ' + name)
        lines.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + name)
    (folder / 'SHA256SUMS.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('plan', 'prepare', 'verify-assets', 'verify-tag'))
    parser.add_argument('--plan', default='build/release-plan.json')
    parser.add_argument('--assets', default='build/packages')
    parser.add_argument('--version')
    args = parser.parse_args()
    if args.command == 'plan':
        result = plan()
        path = ROOT / args.plan
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
                output.write(f"version={result['version']}\npublish={str(result['publish']).lower()}\n")
        print(json.dumps({key: result[key] for key in ('version', 'publish', 'revision')}))
    elif args.command == 'verify-assets':
        verify_assets(ROOT / args.assets, args.version)
    else:
        result = json.loads((ROOT / args.plan).read_text(encoding='utf-8'))
        version = result['version']
        version_tuple(version)
        if args.command == 'prepare':
            if git('rev-parse', 'HEAD') != result['revision']:
                raise ValueError('Build revision changed')
            path = ROOT / PROJECT
            text = path.read_text(encoding='utf-8')
            text = re.sub(r'CURRENT_PROJECT_VERSION = [0-9.]+;', f'CURRENT_PROJECT_VERSION = {version};', text)
            path.write_text(text, encoding='utf-8')
            path = ROOT / CHANGELOG
            text, notes = prepare(path.read_text(encoding='utf-8'), version, result['messages'])
            path.write_text(text, encoding='utf-8')
            (ROOT / 'build/release-notes.md').write_text(notes, encoding='utf-8')
        else:
            tag = 'v' + version
            paths = git('diff', '--name-only', result['revision'], tag).splitlines()
            if any(path not in METADATA for path in paths):
                raise ValueError('Existing tag contains different source')
            for path in METADATA:
                if git('show', tag + ':' + path) != (ROOT / path).read_text(encoding='utf-8').strip():
                    raise ValueError('Existing tag has different release metadata: ' + path)


if __name__ == '__main__':
    main()
