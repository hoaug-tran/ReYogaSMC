import hashlib
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import zipfile
import subprocess
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release', ROOT / 'Scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_semantic_bump_precedence(self):
        self.assertEqual(release.bump('2.0.0', ['fix(driver): bound EC reads']), '2.0.1')
        self.assertEqual(release.bump('2.0.0', ['fix: bounds', 'feat(app): keyboard controls']), '2.1.0')
        self.assertEqual(release.bump('2.0.0', ['feat: controls', 'refactor(driver)!: change protocol']), '3.0.0')
        self.assertEqual(release.bump('2.0.0', ['fix: protocol\n\nBREAKING CHANGE: new selectors']), '3.0.0')

    def test_shipped_changes_only(self):
        for path in ['ReYogaSMC/WMI.cpp', 'ReYogaSMCApp/HardwareViews.swift', 'Scripts/dependencies.json']:
            self.assertTrue(release.shipped(path), path)
        for path in ['README.md', 'Tests/test_release.py', '.github/workflows/main.yml', 'HardwareProfiles/README.md', 'Scripts/release.py']:
            self.assertFalse(release.shipped(path), path)

    def test_changelog_body_is_release_body(self):
        source = '# Releases\n\n## Unreleased\n\n- Add controls.\n\n## 1.5.3\n\n- Upstream release.\n'
        changed, notes = release.prepare(source, '2.0.0', [])
        self.assertEqual(notes, '- Add controls.\n')
        self.assertEqual(release.section(changed, '2.0.0'), notes.strip())
        self.assertEqual(release.prepare(changed, '2.0.0', []), (changed, notes))

    def test_empty_notes_are_rejected(self):
        with self.assertRaises(ValueError):
            release.prepare('# Releases\n', '2.1.0', [])

    def test_project_versions_must_agree(self):
        with self.assertRaises(ValueError):
            release.project_version('CURRENT_PROJECT_VERSION = 2.1.0; CURRENT_PROJECT_VERSION = 2.2.0;')

    def test_asset_manifest_requires_all_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with self.assertRaises(ValueError):
                release.verify_assets(root, '2.0.0')
            manifest = release.package_manifest('2.0.0')
            expected = {f'{mode}/{product}-2.0.0-{mode.upper()}.zip'
                        for mode in ('Debug', 'Release') for product in ('ReYogaSMC', 'ReYogaSMC-App')}
            self.assertEqual(set(manifest), expected)
            for name, required in manifest.items():
                archive_path = root / name
                archive_path.parent.mkdir(exist_ok=True)
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    for member in required:
                        archive.writestr(member, plistlib.dumps({'CFBundleShortVersionString': '2.0.0'})
                                         if member.endswith('/Info.plist') else b'content')
            release.verify_assets(root, '2.0.0')
            checksum_lines = (root / 'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines()
            self.assertEqual(len(checksum_lines), 4)
            for line in checksum_lines:
                _, name = line.split('  ')
                self.assertNotIn('/', name)
                self.assertNotIn('\\', name)
            (root / 'ReYogaSMC-tool-Release.zip').write_bytes(b'extra')
            with self.assertRaises(ValueError):
                release.verify_assets(root, '2.0.0')

    def test_verify_assets_flat_checksum_download_layout(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as flat_dir:
            root = pathlib.Path(directory)
            flat = pathlib.Path(flat_dir)
            manifest = release.package_manifest('2.0.0')
            expected_basenames = {pathlib.Path(name).name for name in manifest}
            self.assertEqual(len(expected_basenames), 4)

            for name, required in manifest.items():
                archive_path = root / name
                archive_path.parent.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    for member in required:
                        if member.endswith('/Info.plist'):
                            archive.writestr(member, plistlib.dumps({'CFBundleShortVersionString': '2.0.0'}))
                        else:
                            archive.writestr(member, f'payload-for-{archive_path.name}-{member}'.encode('utf-8'))

            release.verify_assets(root, '2.0.0')

            sums_content = (root / 'SHA256SUMS.txt').read_text(encoding='utf-8')
            (flat / 'SHA256SUMS.txt').write_text(sums_content, encoding='utf-8')
            for zip_path in root.rglob('*.zip'):
                (flat / zip_path.name).write_bytes(zip_path.read_bytes())

            lines = [line.strip() for line in sums_content.splitlines() if line.strip()]
            self.assertEqual(len(lines), 4)

            listed_names = []
            for line in lines:
                parts = line.split('  ', 1)
                self.assertEqual(len(parts), 2, f'Malformed SHA256SUMS line: {line}')
                expected_hash, filename = parts
                self.assertNotIn('/', filename)
                self.assertNotIn('\\', filename)
                self.assertEqual(filename, pathlib.Path(filename).name)

                target = flat / filename
                self.assertTrue(target.is_file(), f'Missing file in flat download layout: {filename}')
                actual_hash = hashlib.sha256(target.read_bytes()).hexdigest()
                self.assertEqual(actual_hash, expected_hash, f'Hash mismatch for {filename}')
                listed_names.append(filename)

            self.assertEqual(len(listed_names), len(set(listed_names)))
            self.assertEqual(set(listed_names), expected_basenames)

    def test_verify_assets_rejects_duplicate_basenames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            collision_manifest = {
                'Debug/ReYogaSMC-2.0.0.zip': ['ReYogaSMC.kext/Contents/MacOS/ReYogaSMC', 'ReYogaSMC.kext/Contents/Info.plist'],
                'Release/ReYogaSMC-2.0.0.zip': ['ReYogaSMC.kext/Contents/MacOS/ReYogaSMC', 'ReYogaSMC.kext/Contents/Info.plist'],
            }
            for name, required in collision_manifest.items():
                archive_path = root / name
                archive_path.parent.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    for member in required:
                        archive.writestr(member, plistlib.dumps({'CFBundleShortVersionString': '2.0.0'})
                                         if member.endswith('/Info.plist') else b'content')
            with patch.object(release, 'package_manifest', return_value=collision_manifest):
                with self.assertRaisesRegex(ValueError, 'Package basenames must be unique'):
                    release.verify_assets(root, '2.0.0')

    def test_mixed_package_versions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name, required in release.package_manifest('2.0.0').items():
                path = root / name
                path.parent.mkdir(exist_ok=True)
                with zipfile.ZipFile(path, 'w') as archive:
                    for member in required:
                        archive.writestr(member, plistlib.dumps({'CFBundleShortVersionString': '1.5.3'})
                                         if member.endswith('/Info.plist') else b'content')
            with self.assertRaisesRegex(ValueError, 'Packaged version mismatch'):
                release.verify_assets(root, '2.0.0')

    def test_plan_ignores_docs_and_bumps_source_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL)
            git('init')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            (root / release.PROJECT).parent.mkdir(parents=True)
            (root / release.PROJECT).write_text('CURRENT_PROJECT_VERSION = 1.5.3;', encoding='utf-8')
            source = root / 'ReYogaSMC/driver.cpp'
            source.parent.mkdir()
            source.write_text('int value = 1;', encoding='utf-8')
            git('add', release.PROJECT.as_posix(), 'ReYogaSMC/driver.cpp')
            git('commit', '-m', 'fix(driver): initial state')
            git('tag', 'v1.5.3')
            (root / release.PROJECT).write_text('CURRENT_PROJECT_VERSION = 2.0.0;', encoding='utf-8')
            source.write_text('int value = 2;', encoding='utf-8')
            git('add', release.PROJECT.as_posix(), 'ReYogaSMC/driver.cpp')
            git('commit', '-m', 'feat(driver): start ReYogaSMC')
            with patch.object(release, 'ROOT', root):
                self.assertEqual(release.plan()['version'], '2.0.0')
                git('tag', 'v2.0.0')
                self.assertTrue(release.plan()['publish'])
                (root / 'README.md').write_text('Documentation', encoding='utf-8')
                git('add', 'README.md')
                git('commit', '-m', 'docs: installation')
                self.assertFalse(release.plan()['publish'])
                source.write_text('int value = 3;', encoding='utf-8')
                git('add', 'ReYogaSMC/driver.cpp')
                git('commit', '-m', 'feat(driver): add control')
                self.assertEqual(release.plan()['version'], '2.1.0')
                (root / release.PROJECT).write_text('CURRENT_PROJECT_VERSION = 2.0.1;', encoding='utf-8')
                self.assertEqual(release.plan()['version'], '2.0.1', 'An explicit patch version must override automatic feature bumps')
