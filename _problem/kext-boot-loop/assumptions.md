# Assumption log

### A1 - Firmware transport is entered before macOS reaches the desktop
- Source: code-path inspection
- Confidence: high (0.80)
- Impact if wrong: safe-mode hardening will not stop the boot failure
- Cheapest check: boot with `-reysafe`; preserve the last verbose screen and Apple panic log
- Status: open

### A2 - The observed loop is a kernel/firmware boot failure, not a login-item crash
- Source: user description
- Confidence: medium (0.60)
- Impact if wrong: investigation must move from kext start to ReYogaSMCNC launch/login registration
- Cheapest check: record whether the Apple logo restarts, the kernel panics, or the login window appears first
- Status: open
