import importlib.util
import pathlib
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
        self.assertEqual(release.bump('2.1.1', ['fix(driver): bound EC reads']), '2.1.2')
        self.assertEqual(release.bump('2.1.1', ['fix: bounds', 'feat(app): keyboard controls']), '2.2.0')
        self.assertEqual(release.bump('2.1.1', ['feat: controls', 'refactor(driver)!: change protocol']), '3.0.0')
        self.assertEqual(release.bump('2.1.1', ['fix: protocol\n\nBREAKING CHANGE: new selectors']), '3.0.0')

    def test_shipped_changes_only(self):
        for path in ['ReYogaSMC/WMI.cpp', 'ReYogaSMCNC/HardwareViews.swift', 'Scripts/dependencies.json']:
            self.assertTrue(release.shipped(path), path)
        for path in ['README.md', 'Tests/test_release.py', '.github/workflows/main.yml', 'HardwareProfiles/README.md', 'Scripts/release.py']:
            self.assertFalse(release.shipped(path), path)

    def test_changelog_body_is_release_body(self):
        source = '# Releases\n\n## Unreleased\n\n- Add controls.\n\n## 2.1.1\n\n- Older change.\n'
        changed, notes = release.prepare(source, '2.2.0', [])
        self.assertEqual(notes, '- Add controls.\n')
        self.assertEqual(release.section(changed, '2.2.0'), notes.strip())
        self.assertEqual(release.prepare(changed, '2.2.0', []), (changed, notes))

    def test_empty_notes_are_rejected(self):
        with self.assertRaises(ValueError):
            release.prepare('# Releases\n', '2.2.0', [])

    def test_project_versions_must_agree(self):
        with self.assertRaises(ValueError):
            release.project_version('CURRENT_PROJECT_VERSION = 2.1.0; CURRENT_PROJECT_VERSION = 2.2.0;')

    def test_asset_manifest_requires_all_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with self.assertRaises(ValueError):
                release.verify_assets(root)
            for mode in ('Debug', 'Release'):
                (root / mode).mkdir()
                for kind in ('kexts', 'apps', 'tool'):
                    required = {
                        'kexts': ['kexts/ReYogaSMC.kext/Contents/MacOS/ReYogaSMC', 'kexts/ReYogaSMCAlter.kext/Contents/MacOS/ReYogaSMCAlter'],
                        'apps': ['apps/ReYogaSMCNC.app/Contents/MacOS/ReYogaSMCNC', 'apps/ReYogaSMCNC.app/Contents/Library/LoginItems/ReYogaSMCNCHelper.app/Contents/MacOS/ReYogaSMCNCHelper'],
                        'tool': ['tool/ReYoga.cmd', 'tool/ReYoga.command', 'tool/Scripts/hardware_support.py'],
                    }[kind]
                    with zipfile.ZipFile(root / mode / f'ReYogaSMC-{kind}-{mode}.zip', 'w') as archive:
                        for member in required:
                            archive.writestr(member, b'content')
            release.verify_assets(root)
            self.assertEqual(len((root / 'SHA256SUMS.txt').read_text().splitlines()), 6)
            (root / 'extra.zip').write_bytes(b'extra')
            with self.assertRaises(ValueError):
                release.verify_assets(root)

    def test_plan_ignores_docs_and_bumps_source_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL)
            git('init')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            (root / release.PROJECT).parent.mkdir(parents=True)
            (root / release.PROJECT).write_text('CURRENT_PROJECT_VERSION = 2.1.1;')
            source = root / 'ReYogaSMC/driver.cpp'
            source.parent.mkdir()
            source.write_text('int value = 1;')
            git('add', release.PROJECT.as_posix(), 'ReYogaSMC/driver.cpp')
            git('commit', '-m', 'fix(driver): initial state')
            git('tag', 'v2.1.1')
            with patch.object(release, 'ROOT', root):
                self.assertTrue(release.plan()['publish'])
                (root / 'README.md').write_text('Documentation')
                git('add', 'README.md')
                git('commit', '-m', 'docs: installation')
                self.assertFalse(release.plan()['publish'])
                source.write_text('int value = 2;')
                git('add', 'ReYogaSMC/driver.cpp')
                git('commit', '-m', 'feat(driver): add control')
                self.assertEqual(release.plan()['version'], '2.2.0')
