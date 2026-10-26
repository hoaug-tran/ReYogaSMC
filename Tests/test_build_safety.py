"""Behavioral tests verifying build and clean safety against destructive clean, global tmp collisions, and symlink traversal."""

import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def find_bash():
    if sys.platform == "win32":
        candidates = [
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files\Git\usr\bin\bash.exe",
        ]
        for candidate in candidates:
            if os.path.exists(candidate):
                return candidate
    found = shutil.which("bash")
    if found:
        return found
    return "bash"


def can_symlink():
    try:
        with tempfile.TemporaryDirectory() as td:
            src = pathlib.Path(td) / "src"
            src.mkdir()
            dst = pathlib.Path(td) / "dst"
            dst.symlink_to(src, target_is_directory=True)
            return True
    except (OSError, NotImplementedError):
        return False


class BuildSafetyTests(unittest.TestCase):
    def setUp(self):
        self.bash = find_bash()
        try:
            res = subprocess.run([self.bash, "--version"], capture_output=True, text=True)
            if res.returncode != 0:
                self.skipTest("Bash is not runnable in this environment")
        except Exception as e:
            self.skipTest(f"Bash unavailable: {e}")

    def _create_fixture(self, temp_dir):
        """Set up a disposable fixture repo with intercepted xcodebuild and sign-app.sh."""
        repo = pathlib.Path(temp_dir) / "repo"
        scripts = repo / "Scripts"
        scripts.mkdir(parents=True)
        (repo / "ReYogaSMC.xcodeproj").mkdir()

        shutil.copy2(ROOT / "Scripts/build.sh", scripts / "build.sh")
        shutil.copy2(ROOT / "Scripts/clean-build.sh", scripts / "clean-build.sh")

        bin_dir = pathlib.Path(temp_dir) / "bin"
        bin_dir.mkdir()
        xcodebuild_log = pathlib.Path(temp_dir) / "xcodebuild.log"
        fake_xcodebuild = bin_dir / "xcodebuild"
        with fake_xcodebuild.open('w', encoding='utf-8', newline='\n') as handle:
            handle.write(f"#!/bin/sh\necho \"$@\" >> \"{xcodebuild_log.as_posix()}\"\nexit 0\n")
        fake_xcodebuild.chmod(0o777)

        sign_log = pathlib.Path(temp_dir) / "sign.log"
        fake_sign = scripts / "sign-app.sh"
        with fake_sign.open('w', encoding='utf-8', newline='\n') as handle:
            handle.write(f"#!/bin/sh\necho \"$@\" >> \"{sign_log.as_posix()}\"\nexit 0\n")
        fake_sign.chmod(0o777)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir.as_posix()}{os.pathsep}{env.get('PATH', '')}"

        return repo, env, xcodebuild_log, sign_log

    def test_build_routes_per_checkout_without_global_tmp(self):
        with tempfile.TemporaryDirectory() as td:
            repo, env, xcode_log, sign_log = self._create_fixture(td)
            env['TMPDIR'] = td

            res = subprocess.run(
                [self.bash, (repo / "Scripts/build.sh").as_posix(), "Debug"],
                cwd=repo.as_posix(),
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, f"build.sh failed: {res.stderr}")
            self.assertTrue(xcode_log.is_file(), "xcodebuild interceptor did not record invocations")

            log_content = xcode_log.read_text(encoding="utf-8")
            self.assertIn("-configuration Debug", log_content)

            derived_match = re.search(r"-derivedDataPath\s+(\S+)", log_content)
            symroot_match = re.search(r"SYMROOT=(\S+)", log_content)
            objroot_match = re.search(r"OBJROOT=(\S+)", log_content)

            self.assertIsNotNone(derived_match, "Missing -derivedDataPath")
            self.assertIsNotNone(symroot_match, "Missing SYMROOT")
            self.assertIsNotNone(objroot_match, "Missing OBJROOT")

            derived_data = derived_match.group(1)
            symroot = symroot_match.group(1)
            objroot = objroot_match.group(1)

            self.assertTrue(symroot.endswith('/repo/build'))
            self.assertEqual(derived_data, symroot + '/DerivedData')
            self.assertEqual(objroot, symroot + '/Intermediates')
            self.assertNotIn("ReYogaSMC-DerivedData", derived_data)
            self.assertNotIn("ReYogaSMC-Intermediates", objroot)

            self.assertTrue(sign_log.is_file())
            sign_content = sign_log.read_text(encoding="utf-8")
            self.assertTrue(
                sign_content.strip().endswith("/build/Debug"),
                f"sign-app.sh was not invoked with build/Debug: {sign_content}",
            )
            with tempfile.TemporaryDirectory() as sibling:
                repo2, env2, log2, _ = self._create_fixture(sibling)
                env2['TMPDIR'] = td
                result = subprocess.run([self.bash, (repo2 / 'Scripts/build.sh').as_posix(), 'Debug'],
                                        env=env2, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                sibling_derived = re.search(r'-derivedDataPath\s+(\S+)', log2.read_text(encoding='utf-8')).group(1)
                self.assertNotEqual(derived_data, sibling_derived, 'Checkouts sharing TMPDIR must not share DerivedData')

    def test_normal_build_preserves_existing_artifacts_and_overrides(self):
        with tempfile.TemporaryDirectory() as td:
            repo, env, xcode_log, _ = self._create_fixture(td)

            build_dir = repo / "build"
            config_dir = build_dir / "Release"
            config_dir.mkdir(parents=True)
            existing_canary = config_dir / "previous_build.bin"
            existing_canary.write_text("existing product", encoding="utf-8")

            custom_derived = pathlib.Path(td) / "custom_derived"
            custom_derived.mkdir()
            derived_canary = custom_derived / "cached.dat"
            derived_canary.write_text("derived cache", encoding="utf-8")

            custom_obj = pathlib.Path(td) / "custom_obj"
            custom_obj.mkdir()
            obj_canary = custom_obj / "cached.o"
            obj_canary.write_text("intermediate object", encoding="utf-8")

            env["DERIVED_DATA_PATH"] = custom_derived.as_posix()
            env["OBJROOT_PATH"] = custom_obj.as_posix()

            res = subprocess.run(
                [self.bash, (repo / "Scripts/build.sh").as_posix(), "Release"],
                cwd=repo.as_posix(),
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, f"build.sh failed: {res.stderr}")

            self.assertTrue(existing_canary.is_file(), "build.sh wiped existing configuration products")
            self.assertEqual(existing_canary.read_text(encoding="utf-8"), "existing product")

            self.assertTrue(derived_canary.is_file(), "build.sh wiped DERIVED_DATA_PATH override")
            self.assertTrue(obj_canary.is_file(), "build.sh wiped OBJROOT_PATH override")

            log_content = xcode_log.read_text(encoding="utf-8")
            self.assertIn(f"-derivedDataPath {custom_derived.as_posix()}", log_content)
            self.assertIn(f"OBJROOT={custom_obj.as_posix()}", log_content)

    def test_build_and_clean_with_unset_and_empty_tmpdir(self):
        with tempfile.TemporaryDirectory() as td:
            repo, env, _, _ = self._create_fixture(td)
            for value in (None, ''):
                with self.subTest(TMPDIR=value):
                    if value is None:
                        env.pop('TMPDIR', None)
                    else:
                        env['TMPDIR'] = value
                    for script in ('build.sh', 'clean-build.sh'):
                        result = subprocess.run([self.bash, (repo / 'Scripts' / script).as_posix()],
                                                cwd=repo, env=env, capture_output=True, text=True, timeout=30)
                        self.assertEqual(result.returncode, 0, result.stderr)


    def test_clean_build_removes_exact_artifacts(self):
        with tempfile.TemporaryDirectory() as td:
            repo, env, _, _ = self._create_fixture(td)

            build_dir = repo / "build"
            build_dir.mkdir(parents=True)

            exact_targets = [
                build_dir / "Debug",
                build_dir / "Release",
                build_dir / "DerivedData",
                build_dir / "Intermediates",
                build_dir / "packages",
                build_dir / "ReYogaUIReview",
                build_dir / "HardwareProfiles",
            ]
            for target in exact_targets:
                target.mkdir()
                (target / "dummy.dat").write_text("artifact", encoding="utf-8")

            (build_dir / "SupportTests").write_text("test executable", encoding="utf-8")
            (build_dir / "release-plan.json").write_text("{}", encoding="utf-8")
            (build_dir / "release-notes.md").write_text("notes", encoding="utf-8")
            (build_dir / "debug.log").write_text("log content", encoding="utf-8")
            (build_dir / "release.log").write_text("log content", encoding="utf-8")

            verify_dir = repo / ".verify-derived-test"
            verify_dir.mkdir()
            (verify_dir / "check.tmp").write_text("tmp", encoding="utf-8")

            clean_res = subprocess.run(
                [self.bash, (repo / "Scripts/clean-build.sh").as_posix()],
                cwd=repo.as_posix(),
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(clean_res.returncode, 0, f"clean-build.sh failed: {clean_res.stderr}")

            for target in exact_targets:
                self.assertFalse(target.exists(), f"Exact artifact {target.name} was not removed")
            self.assertFalse((build_dir / "SupportTests").exists())
            self.assertFalse((build_dir / "release-plan.json").exists())
            self.assertFalse((build_dir / "release-notes.md").exists())
            self.assertFalse((build_dir / "debug.log").exists())
            self.assertFalse((build_dir / "release.log").exists())
            self.assertTrue((verify_dir / "check.tmp").is_file(), "Legacy prefix must not authorize deleting a directory")

    def test_clean_build_preserves_user_and_checked_files(self):
        with tempfile.TemporaryDirectory() as td:
            repo, env, _, _ = self._create_fixture(td)

            checked_file = repo / "README.md"
            checked_file.write_text("# Project", encoding="utf-8")

            build_dir = repo / "build"
            build_dir.mkdir(parents=True)

            (build_dir / "Debug").mkdir()
            (build_dir / "Debug" / "app.bin").write_text("bin", encoding="utf-8")
            (build_dir / "build.log").write_text("log", encoding="utf-8")

            user_notes = build_dir / "my_notes.txt"
            user_notes.write_text("important user notes", encoding="utf-8")
            user_tool = build_dir / "custom_tool.py"
            user_tool.write_text("print('hello')", encoding="utf-8")
            user_dir = build_dir / "my_experiments"
            user_dir.mkdir()
            (user_dir / "data.csv").write_text("1,2,3", encoding="utf-8")

            clean_res = subprocess.run(
                [self.bash, (repo / "Scripts/clean-build.sh").as_posix()],
                cwd=repo.as_posix(),
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(clean_res.returncode, 0, f"clean-build.sh failed: {clean_res.stderr}")

            self.assertFalse((build_dir / "Debug").exists())
            self.assertFalse((build_dir / "build.log").exists())

            self.assertTrue(user_notes.is_file(), "User notes in build dir were deleted")
            self.assertEqual(user_notes.read_text(encoding="utf-8"), "important user notes")
            self.assertTrue(user_tool.is_file(), "User tool in build dir was deleted")
            self.assertTrue((user_dir / "data.csv").is_file(), "User directory was deleted")
            self.assertTrue(checked_file.is_file(), "Checked project file was deleted")

    def test_clean_build_preserves_external_symlink_target(self):
        if not can_symlink():
            self.skipTest("Symlinks not supported in current environment")

        with tempfile.TemporaryDirectory() as td:
            repo, env, _, _ = self._create_fixture(td)

            sibling_checkout = pathlib.Path(td) / "sibling_checkout"
            sibling_checkout.mkdir()
            sibling_canary = sibling_checkout / "keep.txt"
            sibling_canary.write_text("precious sibling data", encoding="utf-8")
            sibling_sub = sibling_checkout / "nested"
            sibling_sub.mkdir()
            (sibling_sub / "artifact.dat").write_text("nested data", encoding="utf-8")

            build_link = repo / "build"
            build_link.symlink_to(sibling_checkout, target_is_directory=True)

            clean_res = subprocess.run(
                [self.bash, (repo / "Scripts/clean-build.sh").as_posix()],
                cwd=repo.as_posix(),
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(clean_res.returncode, 0, f"clean-build.sh failed: {clean_res.stderr}")

            self.assertTrue(sibling_checkout.is_dir(), "Sibling checkout directory was deleted")
            self.assertTrue(sibling_canary.is_file(), "Sibling canary file was deleted")
            self.assertEqual(sibling_canary.read_text(encoding="utf-8"), "precious sibling data")
            self.assertTrue((sibling_sub / "artifact.dat").is_file(), "Sibling nested data was deleted")

    def test_clean_build_preserves_symlink_target_inside_build(self):
        if not can_symlink():
            self.skipTest("Symlinks not supported in current environment")

        with tempfile.TemporaryDirectory() as td:
            repo, env, _, _ = self._create_fixture(td)

            external_dir = pathlib.Path(td) / "external_target"
            external_dir.mkdir()
            external_file = external_dir / "precious.txt"
            external_file.write_text("precious external data", encoding="utf-8")

            build_dir = repo / "build"
            build_dir.mkdir(parents=True)

            (build_dir / "Debug").symlink_to(external_dir, target_is_directory=True)

            clean_res = subprocess.run(
                [self.bash, (repo / "Scripts/clean-build.sh").as_posix()],
                cwd=repo.as_posix(),
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(clean_res.returncode, 0, f"clean-build.sh failed: {clean_res.stderr}")

            self.assertTrue(external_dir.is_dir(), "External target directory was deleted")
            self.assertTrue(external_file.is_file(), "External target file was deleted")
            self.assertEqual(external_file.read_text(encoding="utf-8"), "precious external data")
            self.assertFalse((build_dir / "Debug").exists())

    def test_clean_build_preserves_external_build_dir_override(self):
        with tempfile.TemporaryDirectory() as td:
            repo, env, _, _ = self._create_fixture(td)

            override_dir = pathlib.Path(td) / "override_build"
            override_dir.mkdir()
            override_file = override_dir / "keep.txt"
            override_file.write_text("precious override file", encoding="utf-8")

            env["BUILD_DIR"] = override_dir.as_posix()

            clean_res = subprocess.run(
                [self.bash, (repo / "Scripts/clean-build.sh").as_posix()],
                cwd=repo.as_posix(),
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(clean_res.returncode, 0, f"clean-build.sh failed: {clean_res.stderr}")

            self.assertTrue(override_dir.is_dir(), "Override build directory was deleted")
            self.assertTrue(override_file.is_file(), "File in override build directory was deleted")
            self.assertEqual(override_file.read_text(encoding="utf-8"), "precious override file")

    def test_static_script_safety_and_compatibility(self):
        build_text = (ROOT / "Scripts/build.sh").read_text(encoding="utf-8")
        clean_text = (ROOT / "Scripts/clean-build.sh").read_text(encoding="utf-8")

        for script_name, text in [("build.sh", build_text), ("clean-build.sh", clean_text)]:
            self.assertNotIn("declare -A", text, f"{script_name} uses Bash 4 associative arrays")
            self.assertNotIn("readarray", text, f"{script_name} uses Bash 4 readarray")
            self.assertNotIn("mapfile", text, f"{script_name} uses Bash 4 mapfile")
            self.assertNotIn("|&", text, f"{script_name} uses Bash 4 |&")

            self.assertNotRegex(
                text,
                r"chown\s+-R\s+\"\$SUDO_USER\"\s+\"\$root/build\"\s*2>/dev/null",
                f"{script_name} contains blind recursive chown without -P/-h symlink guard",
            )

            self.assertNotIn(
                "${TMPDIR%/}/ReYogaSMC-DerivedData",
                text,
                f"{script_name} references global TMPDIR ReYogaSMC-DerivedData",
            )
            self.assertNotIn(
                "${TMPDIR%/}/ReYogaSMC-Intermediates",
                text,
                f"{script_name} references global TMPDIR ReYogaSMC-Intermediates",
            )

        self.assertIn('derived_data="${DERIVED_DATA_PATH:-$build_dir/DerivedData}"', build_text)
        self.assertIn('obj_root="${OBJROOT_PATH:-$build_dir/Intermediates}"', build_text)
        self.assertNotIn('rm -rf "$build_dir/$configuration"', build_text)
        self.assertNotIn('rm -rf "$derived_data"', build_text)
        self.assertNotIn('rm -rf "$obj_root"', build_text)


if __name__ == "__main__":
    unittest.main()
