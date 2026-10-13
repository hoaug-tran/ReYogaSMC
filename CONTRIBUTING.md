# Contributing to ReYogaSMC

A useful contribution makes a hardware claim reviewable. Explain the machine, firmware and behavior that led to the change.

## Device support

Start with `python3 Scripts/hardware_support.py --acpi /path/to/tables`. Review the report and tables before sharing them. Include the exact model, BIOS version, macOS version, loaded driver version and the feature you want to support.

A profile must include firmware fingerprints, source evidence, addresses and units, capability requirements and validation status. Similar models are not evidence for shared EC layouts. Do not copy another model's offsets or weaken firmware matching to make an unknown device pass.

Keep hardware values in profiles. Keep wire-format constants in their protocol adapter. Separate sensor support from writable control support. `verified_writes` stays zero until a maintainer has reviewed successful hardware validation and restoration behavior. A DSDT hash match alone never validates a write.

For writable interfaces, record requested and actual values, allowed range/step, failure behavior, reset, power-mode changes, AC/battery and sleep/wake. Never retry a command that caused shutdown or loss of cooling. Document what remains unverified.

## Code changes

Preserve upstream authorship and license notices. Explain the final behavior and any ABI changes. Keep original service names and bundle IDs unless a migration is part of the change. A product rename must also update packaging, helper lookup and release scripts.

Do not add machine-specific fallbacks to shared code. Avoid optimistic hardware state, silent failed calls and success messages based only on transport acknowledgement. Errors should say which stage failed, what was requested, what was observed and the next useful action.

Build the affected targets and run relevant checks. A firmware change needs a booted hardware result; an unsigned build is not permission-persistence validation. Runtime testing on one macOS version does not establish support for every version.

## Pull requests

Use the PR template. Keep changes focused and attach reproducible evidence. State which checks ran and which hardware or OS versions remain untested. Include compiler output only when it explains a failure.

Source control should contain source, profiles, useful documentation and maintained tests. Keep build products, logs, device dumps, credentials, personal notes and internal review transcripts out of commits. Do not remove legitimate protocol terms or author credits during cleanup.

## Working together

Discuss the behavior and evidence. Respect contributors, explain disagreements and avoid personal attacks. Report security issues through the process in SECURITY.md.
