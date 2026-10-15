# Differential diagnosis

| Candidate | Evidence and prediction | Cheapest separating check | Status |
|---|---|---|---|
| Early ACPI/EC/WMI access | `IdeaVPC::start` reaches virtual `updateAll`; WMI examination triggers another full update and starts 500 ms telemetry. If causal, `-reysafe` boots. | Boot once with `-reysafe` | leading, unverified |
| Kext/dependency or personality failure | If causal, safe mode still fails before/while the service attaches. | Compare verbose/panic logs with kext disabled and with `-reysafe` | rival, unverified |
| SSDT bridge namespace or SystemMemory mapping | If causal, removing only SSDT-ReYoga while retaining the safe kext changes the outcome, or panic names ACPI/bridge methods. | A/B SSDT with safe mode and inspect panic | rival, unverified |

The present patch adds a model-independent isolation switch. It does not claim the hardware root cause is proven without a target-machine boot and panic evidence.
