# Contributing

## Report a device problem

Use the app's Diagnostics export or the [hardware tool](Docs/hardware-tool.md). Review files before sharing them. Include the model, BIOS, OS, app/kext versions, failing action and expected result. Note AC/battery and sleep/wake differences.

Report private security details through [SECURITY.md](SECURITY.md).

## Change device support

Read the relevant firmware methods and upstream protocol code before changing controls. Record units, allowed values, response format and failure behavior. Similar model names do not prove shared EC layouts.

Keep device-specific values in [hardware profiles](HardwareProfiles/README.md) or their backend. Sensor support and write permission are separate. Raw-offset bridges need reviewed fingerprints and addresses. `verified_writes` stays zero until writes, readback and recovery have been checked on the target firmware.

For a writable control, check range/step, rejection, reset, power-profile changes, AC/battery and sleep/wake. Stop testing a command that caused shutdown or loss of cooling.

## Code layout

Use names that describe the file's main type or job. Keep stable IDs, persisted keys, wire formats, licenses and upstream credits unchanged during renaming.

| Directory | Contents |
| --- | --- |
| `ReYogaSMC/Platform/` | Firmware backends, lifecycle, telemetry and controls |
| `ReYogaSMC/SMC/`, `ReYogaSMC/WMI/` | VirtualSMC keys and WMI interfaces |
| `ReYogaSMC/ACPIExamples/` | ACPI samples for manual review |
| `ReYogaSMCApp/Application/` | App lifecycle, windows and driver connection ownership |
| `ReYogaSMCApp/Hardware/` | Device state, capability checks and hardware transactions |
| `ReYogaSMCApp/Views/` | UI, dialogs, formatting and HUD |
| `ReYogaSMCApp/Events/`, `Preferences/`, `Diagnostics/`, `System/` | Event mappings, app settings, report collection and macOS actions |

Views receive state and actions explicitly. Hardware code must not locate `AppDelegate` or open dialogs. Keep one owner for each connection, queue and mutable state. Update Xcode groups, target membership, script inputs and tests when moving a source file.

Translate UI labels, errors and status messages in both `en.lproj` and `vi.lproj`. Existing English message keys may be returned by services and translated where displayed. Keep format arguments, firmware keys, ACPI names and log identifiers unchanged.

## Build and test

Use macOS with Xcode for app/kext builds. Read [Scripts/dependencies.json](Scripts/dependencies.json) before replacing dependencies. Bootstrap rejects changed SDK files and mismatched cached bundles.

```sh
bash Scripts/bootstrap.sh
python3 -B -m unittest discover -s Tests -p "test_*.py" -v
python3 -B Scripts/generate_firmware_profiles.py --check
python3 -B Scripts/check_format.py
bash Scripts/test-support.sh
bash Scripts/build.sh Debug
bash Scripts/build.sh Release
git diff --check
```

When profile JSON changes, run `python3 Scripts/generate_firmware_profiles.py` before `--check`. Do not edit the generated header by hand.

Tests should execute production logic with independent inputs. A source-wiring check does not replace a runtime test. Report skipped tests and missing tools.

### Device flows

```sh
python3 -B Scripts/check_device_flows.py
python3 -B Scripts/check_device_flows.py --native
```

The first command needs macOS/Linux, Swift, a C++ compiler, `iasl` and `acpiexec`. It runs device/control replays and writes logs, source hashes and a feature matrix to `build/device-flows/`. Missing tools or incomplete results fail the run.

`--native` also requires macOS/Xcode. It runs support checks, Debug/Release builds and UI fixture renders in English and Vietnamese. Tests use sanitized or synthetic snapshots; they do not install a kext or certify physical device behavior. Check hardware changes on the target machine before calling them verified.

### Signing and packages

```sh
bash Scripts/sign-app.sh 'Developer ID Application: Your Name (TEAMID)' build/Release
bash Scripts/package.sh Debug
bash Scripts/package.sh Release
python3 Scripts/release.py verify-assets
```

Keep the same signing identity across app updates when possible. Ad-hoc builds may need privacy approval again. Signing does not sign the kext or test firmware behavior.

Builds record source hashes. Packaging rejects source changes after a build and mismatched Debug/Release snapshots. Archives include source manifests; `BUILD_PROVENANCE.json` and `SHA256SUMS.txt` describe the packaged files.

## Pull requests

Use the PR template. Describe the problem, resulting behavior, relevant tests and remaining target checks. Keep logs, device dumps, build products, credentials and task notes out of commits.

Use Conventional Commits, such as `fix(driver): ...`, `feat(app): ...`, `docs: ...` or `test: ...`. Add notes to the pending version in [Changelog.md](Changelog.md); leave published release entries unchanged.

The main workflow tests all platforms before building and packaging. Pull requests run native checks without publishing. Release preparation requires clean source. Shipped changes can trigger a release; documentation, tests and CI changes alone do not. A manually increased project version takes precedence over the calculated version.

Release notes come from the versioned changelog section. Publishing creates the metadata commit, tag and release assets only after checks pass. Existing tags must match the expected source before a rerun can replace assets.
