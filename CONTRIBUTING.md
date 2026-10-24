# Contributing to ReYogaSMC

Include the affected model, firmware version, observed behavior and validation results.

## Device support

Start with `python3 Scripts/hardware_support.py --acpi /path/to/tables`. Review the report and tables before sharing them. Include the exact model, BIOS version, macOS version, loaded driver version and the feature you want to support.

A profile must include firmware fingerprints, source evidence, addresses and units, capability requirements and validation status. Similar models are not evidence for shared EC layouts. Do not copy another model's offsets or weaken firmware matching to make an unknown device pass.

Keep hardware values in profiles. Keep wire-format constants in their protocol adapter. Separate sensor support from writable control support. `verified_writes` stays zero until a maintainer has reviewed successful hardware validation and restoration behavior. A DSDT hash match alone never validates a write.

For writable interfaces, record requested and actual values, allowed range/step, failure behavior, reset, power-mode changes, AC/battery and sleep/wake. Never retry a command that caused shutdown or loss of cooling. Document what remains unverified.

## Code changes

Preserve upstream authorship and license notices. Explain the final behavior and any ABI changes. Changes to service names or bundle IDs need a migration. A product rename must also update packaging, helper lookup and release scripts.

Do not add machine-specific fallbacks to shared code. Avoid optimistic hardware state, silent failed calls and success messages based only on transport acknowledgement. Errors should say which stage failed, what was requested, what was observed and the next useful action.

Build the affected targets and run relevant checks. A firmware change needs a booted hardware result; an unsigned build is not permission-persistence validation. Runtime testing on one macOS version does not establish support for every version.

## Pull requests

Use the PR template. Keep changes focused and attach reproducible evidence. State which checks ran and which hardware or OS versions remain untested. Include compiler output only when it explains a failure.

Source control should contain source, profiles, useful documentation and maintained tests. Keep build products, logs, device dumps, credentials, personal notes out of commits. Do not remove legitimate protocol terms or author credits during cleanup.

## Working together

Discuss the behavior and evidence. Respect contributors, explain disagreements and avoid personal attacks. Report security issues through the process in SECURITY.md.

## Commits and releases

Use Conventional Commits: `fix(driver): ...`, `feat(app): ...`, `docs: ...`, `test: ...` or `ci: ...`. Add release notes under `## Unreleased` in Changelog.md.

A successful main build releases changes to shipped driver, app, profiles or tools. Breaking changes (`!` or a `BREAKING CHANGE:` footer) bump the major version; `feat` bumps minor; other shipped changes bump patch. Documentation, tests and CI changes alone do not create a release. A manually increased project version takes precedence.

The workflow builds and tests both configurations before publishing. It commits only the version/changelog metadata, tags that commit and uses the changelog section as the GitHub Release description. Release assets are the main kext, Alter kext and app, each in DEBUG and RELEASE ZIPs, plus SHA256SUMS.txt. Collection scripts stay in the source repository. Existing tags must match the built source and expected metadata before a rerun can update assets.
