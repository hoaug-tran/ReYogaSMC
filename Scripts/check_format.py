"""Check shared UTF-8, LF and whitespace rules without rewriting files."""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {'.c', '.cpp', '.m', '.h', '.hpp', '.swift', '.py', '.sh', '.ps1', '.cmd',
                 '.command', '.md', '.json', '.yml', '.yaml', '.dsl', '.strings'}


def violations(data):
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return ['not valid UTF-8']
    errors = []
    if '\r' in text:
        errors.append('use LF line endings')
    if text and not text.endswith('\n'):
        errors.append('missing final newline')
    for number, line in enumerate(text.splitlines(), 1):
        if line.rstrip(' \t') != line:
            errors.append(f'{number}: trailing whitespace')
    return errors


def main():
    result = subprocess.run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
                            cwd=ROOT, check=True, capture_output=True)
    checked = 0
    failures = []
    for name in sorted(set(result.stdout.decode('utf-8').split('\0')) - {''}):
        path = ROOT / name
        if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
            continue
        checked += 1
        failures.extend(f'{name}: {error}' for error in violations(path.read_bytes()))
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f'Format: {checked} files, {len(failures)} violations')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
