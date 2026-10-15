# Diagnostic rollout

1. Agent: build and publish the revision with passive-by-default CPU power access and diagnostic boundaries. Do not mix in unrelated working-tree mode changes.
2. User: retain a recoverable EFI with -reysafe. Test only an artifact whose CI commit matches this patch, with -v keepsyms=1 debug=0x100 -reytrace -reynowmi -reynobridge, without -reysafe or -reycpupower.
3. If it boots, remove only -reynowmi. If it still boots, remove only -reynobridge. Retain log/panic and stop at the first failure. Do not alter SSDTs or other kexts between tests.

Success: ordinary boot without isolation flags, plausible sensors, individually verified control readbacks and sleep/wake. CPU-power and manual fan writes remain separately gated and are not certified by boot success.

Pivot: if the first diagnostic configuration fails, investigate the last legacy ACPI/EC initialization or refresh boundary. If WMI re-enabling fails, distinguish _WDG/BMF parsing from method invocation using entry/return logs. If only bridge re-enabling fails, investigate RYxx namespace/SystemMemory access. A last log line is a lead, not proof; panic/backtrace evidence takes precedence. If all stages pass, revisit CPU-power involvement without enabling it until a separate validation is agreed.

Runtime review remains pending on the target macOS machine. No EFI changes or firmware writes were performed during this patch.
