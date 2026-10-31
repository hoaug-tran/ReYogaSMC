## Description

Describe the changes proposed in this pull request and the rationale behind them.

## Subsystem & Hardware

- Target hardware: (e.g. ThinkPad HKEY, IdeaPad ACPI, Legion WMI, App UI, Core)
- Tested models & BIOS:
- ACPI / WMI methods or protocol references:

## Checklist

- [ ] I have not hardcoded machine identifiers or unreviewed firmware hashes.
- [ ] No experimental raw EC RAM table writes are enabled without hardware write validation.
- [ ] All automated support tests pass (`bash Scripts/test-support.sh` and `python3 -B -m unittest discover -s Tests`).
- [ ] Code formatting adheres to project rules (`python3 -B Scripts/check_format.py`).
- [ ] Both English (`en.lproj`) and Vietnamese (`vi.lproj`) localization strings are updated if UI text changed.
- [ ] Documentation (`README.md`, `Docs/compatibility.md`) and `Changelog.md` updated if applicable.
