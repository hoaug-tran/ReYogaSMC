# Assumption log

### A1 - Firmware transport is entered before macOS reaches the desktop
- Source: code-path inspection
- Confidence: high (0.80)
- Impact if wrong: safe-mode hardening will not stop the boot failure
- Cheapest check: boot with `-reysafe`; preserve the last verbose screen and Apple panic log
- Status: open
- Result (2026-10-15): supplied macOS log and user report confirm safe-mode boot to desktop. This supports the skipped-path group but does not distinguish ACPI transport, bridge access or WMI parser failure.

### A2 - The observed loop is a kernel/firmware boot failure, not a login-item crash
- Source: user description
- Confidence: medium (0.60)
- Impact if wrong: investigation must move from kext start to ReYogaSMCNC launch/login registration
- Cheapest check: record whether the Apple logo restarts, the kernel panics, or the login window appears first
- Status: open

### A3 - Implicit CPU power-range queries contribute to the normal-boot failure
- Source: reviewed DSDT getters can write SystemMemory; automatic feature refresh called them repeatedly
- Confidence: medium (0.55); side effects are confirmed, causal connection is not
- Impact if wrong: default-off CPU power access removes a real risk but does not repair the whole boot-loop
- Cheapest check: boot the new revision without -reycpupower, then split WMI/bridge paths using the documented isolation flags
- Status: open; user requested continued implementation after safe-boot result, runtime proof pending
