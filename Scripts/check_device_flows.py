"""Run source-linked device replays and report coverage without claiming hardware validation."""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    from .release import source_snapshot
except ImportError:
    from release import source_snapshot

ROOT = pathlib.Path(__file__).resolve().parents[1]
AREAS = {
    'identity_and_profiles': ['test_firmware_identity', 'test_firmware_profiles', 'test_profile_schemas'],
    'controls_readback_restore': ['test_device_flows', 'test_control_request', 'test_recovery_inputs'],
    'dytc_profiles': ['test_dytc_replay'],
    'thinkpad_fan_curve_watchdog': ['test_think_fan', 'test_curve_watchdog'],
    'acpi_capture_generation_verification': ['test_acpi_capture', 'test_acpi_lifecycle', 'test_thinkpad_analysis', 'test_thinkpad_acpi_runtime', 'test_acpi_samples'],
    'backlight': ['test_backlight_policy', 'test_device_flows'],
    'lighting_and_hotkeys_lifecycle': ['test_lighting_lifecycle', 'test_hotkey_lifecycle'],
    'login_items_policy': ['test_login_item'],
    'shutdown': ['test_manager_shutdown', 'test_device_flows'],
    'hp_sensors_and_kernel_resources': ['test_hp_sensor_schema', 'test_kernel_allocations'],
    'update_and_release': ['test_release_service', 'test_release', 'test_build_safety'],
    'localization_and_source_wiring': ['test_localization', 'test_project_structure', 'test_format'],
    'report_collectors': ['test_hardware_support', 'test_windows_support', 'test_ec_reader'],
}


class FlowResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.outcomes = []

    def record(self, test, state, reason=None):
        self.outcomes.append({'test': test.id(), 'module': test.__class__.__module__.removeprefix('Tests.'),
                              'state': state, 'reason': reason})

    def addSuccess(self, test):
        self.record(test, 'passed')
        super().addSuccess(test)

    def addFailure(self, test, error):
        self.record(test, 'failed')
        super().addFailure(test, error)

    def addError(self, test, error):
        self.record(test, 'error')
        super().addError(test, error)

    def addSkip(self, test, reason):
        self.record(test, 'skipped', reason)
        super().addSkip(test, reason)

    def addSubTest(self, test, subtest, error):
        if error is not None:
            self.record(test, 'failed' if issubclass(error[0], test.failureException) else 'error', str(subtest))
        super().addSubTest(test, subtest, error)


def area_coverage(outcomes):
    result = {}
    for area, modules in AREAS.items():
        rows = [row for row in outcomes if row['module'] in modules]
        states = {row['state'] for row in rows}
        if states & {'failed', 'error'}:
            status = 'failed'
        elif 'skipped' in states:
            status = 'partial'
        else:
            status = 'passed_software_tests' if rows else 'not_run'
        result[area] = {'state': status, 'tests': [row['test'] for row in rows]}
    return result


def command(arguments, output, name, environment, timeout=900):
    log = output / (name + '.log')
    try:
        with log.open('w', encoding='utf-8') as stream:
            result = subprocess.run(arguments, cwd=ROOT, env=environment, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=timeout, check=False)
        return {'state': 'passed' if result.returncode == 0 else 'failed', 'exit': result.returncode, 'log': str(log)}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'state': 'failed', 'error': str(error), 'log': str(log)}


def run(output, native=False):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'schemaVersion': 1, 'scope': 'software_replay_and_native' if native else 'software_replay',
              'status': 'incomplete', 'hardware': 'not_run', 'native': {'state': 'not_run'},
              'unverified': ['Physical device I/O, fan RPM response, LEDs, sleep/wake and OS permission/registration behavior',
                             'Interactive UI behavior; rendered fixtures do not execute every button']}

    def finish(exit_code):
        (output / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        print(json.dumps({'status': report['status'], 'scope': report['scope'], 'report': str(output / 'report.json')}, ensure_ascii=False))
        return exit_code

    required = ['swiftc', 'iasl', 'acpiexec']
    missing = [name for name in required if not shutil.which(name)]
    if not (shutil.which('clang++') or shutil.which('g++')):
        missing.append('clang++ or g++')
    if sys.platform not in ('darwin', 'linux'):
        missing.append('macOS or Linux host for connected Swift replays')
    if native and (sys.platform != 'darwin' or not shutil.which('xcodebuild')):
        missing.append('macOS with Xcode for --native')
    if missing:
        report['missing'] = missing
        return finish(2)

    before = source_snapshot()
    (output / 'source.json').write_text(json.dumps(before, indent=2) + '\n', encoding='utf-8')
    flow_report = output / 'device-matrix.json'
    if flow_report.exists():
        flow_report.unlink()  # Never accept the previous run's matrix when the replay fails or skips.
    previous = os.environ.get('REYOGA_DEVICE_FLOW_REPORT')
    os.environ['REYOGA_DEVICE_FLOW_REPORT'] = str(flow_report)
    try:
        if str(ROOT) not in sys.path:
            sys.path.insert(0, str(ROOT))
        suite = unittest.defaultTestLoader.discover(str(ROOT / 'Tests'), pattern='test_*.py')
        with (output / 'tests.log').open('w', encoding='utf-8') as stream:
            result = unittest.TextTestRunner(stream=stream, verbosity=2, resultclass=FlowResult).run(suite)
    finally:
        if previous is None:
            os.environ.pop('REYOGA_DEVICE_FLOW_REPORT', None)
        else:
            os.environ['REYOGA_DEVICE_FLOW_REPORT'] = previous
    report['tests'] = {'total': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
                       'skipped': [{'test': test.id(), 'reason': reason} for test, reason in result.skipped], 'log': str(output / 'tests.log')}
    report['areas'] = area_coverage(result.outcomes)
    report['outcomes'] = result.outcomes
    environment = os.environ.copy()
    report['checks'] = {
        'profiles': command([sys.executable, '-B', 'Scripts/generate_firmware_profiles.py', '--check'], output, 'profiles', environment),
        'format': command([sys.executable, '-B', 'Scripts/check_format.py'], output, 'format', environment),
        'diff': command(['git', 'diff', '--check'], output, 'diff', environment),
    }
    if native:
        native_checks = {}
        for name, arguments in [('support', ['bash', 'Scripts/test-support.sh']),
                                ('debug', ['bash', 'Scripts/build.sh', 'Debug']),
                                ('release', ['bash', 'Scripts/build.sh', 'Release'])]:
            native_checks[name] = command(arguments, output, 'native-' + name, environment)
            if native_checks[name]['state'] != 'passed':
                break
        if len(native_checks) == 3 and all(item['state'] == 'passed' for item in native_checks.values()):
            for language in ('en', 'vi'):
                directory = pathlib.Path(tempfile.mkdtemp(prefix='ui-' + language + '-', dir=output))
                render_environment = dict(environment, REYOGA_UI_FIXTURE=str(ROOT / 'Tests/ui-fixture.json'),
                                          REYOGA_UI_REVIEW_DIR=str(directory))
                rendered = command([str(ROOT / 'build/Debug/ReYogaSMC.app/Contents/MacOS/ReYogaSMC'),
                                    '--render-ui', '-AppleLanguages', '(' + language + ')'],
                                   output, 'ui-' + language, render_environment, timeout=180)
                rendered['images'] = len(list((directory / 'ReYogaUIReview').glob('*.png')))
                rendered['directory'] = str(directory)
                if rendered['images'] != 26:
                    rendered['state'] = 'failed'
                native_checks['ui-' + language] = rendered
        report['native'] = {'state': 'passed' if len(native_checks) == 5 and all(item['state'] == 'passed' for item in native_checks.values()) else 'failed',
                            'checks': native_checks}
    report['sourceUnchanged'] = source_snapshot() == before
    matrix_ok = False
    if flow_report.exists():
        matrix = json.loads(flow_report.read_text(encoding='utf-8'))
        expected = json.loads((ROOT / 'Tests/Fixtures/device_flows.json').read_text(encoding='utf-8'))
        expected_ids = {case['id'] for case in expected['cases']}
        actual_ids = [case['id'] for case in matrix.get('cases', [])]
        matrix_ok = matrix.get('status') == 'software_replay_passed' and set(actual_ids) == expected_ids and len(actual_ids) == len(expected_ids)
        report['devices'] = matrix
    excluded = {'PowerShell parser is available on Windows'}
    unexpected_skips = [reason for _, reason in result.skipped if reason not in excluded]
    passed = (result.wasSuccessful() and not unexpected_skips and matrix_ok and report['sourceUnchanged'] and
              all(item['state'] == 'passed' for item in report['checks'].values()) and (not native or report['native']['state'] == 'passed'))
    report['status'] = 'software_and_native_passed' if passed and native else 'software_passed' if passed else 'failed_or_incomplete'
    return finish(0 if passed else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build/device-flows')
    parser.add_argument('--native', action='store_true', help='Also require macOS support checks and Debug/Release builds')
    args = parser.parse_args()
    return run(args.output, native=args.native)


if __name__ == '__main__':
    raise SystemExit(main())
