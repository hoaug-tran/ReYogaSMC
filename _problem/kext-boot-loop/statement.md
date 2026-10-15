# Problem statement

ReYogaSMC is reported to prevent a Lenovo Legion 7 2021 from reaching the macOS desktop. The exact terminal symptom (panic, watchdog reboot, freeze, or userspace login loop) and panic log are not yet available.

Success means the machine boots with the kext present, unsupported firmware paths remain passive, and hardware access is enabled only after capability evidence rather than a model-name hardcode.

## Boundary known so far

| | IS | IS NOT / UNKNOWN |
|---|---|---|
| Trigger | ReYogaSMC enabled | Reported behavior with kext disabled is not yet captured |
| Hardware | Legion 7 2021 / 16ACHg6 family | Other models unknown |
| Stage | Before the main desktop | Exact last verbose line unknown |
| Form | Repeated boot failure | Panic vs watchdog vs hang unknown |
