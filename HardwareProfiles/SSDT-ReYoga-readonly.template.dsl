// SPDX-License-Identifier: GPL-2.0-only
// Reviewed named-field telemetry bridge. No raw offsets or firmware writes.
// Profile: {{profile_name}}
DefinitionBlock ("", "SSDT", 2, "REYOGA", "RYLG", 0x00000001)
{
    External ({{ec_path}}, DeviceObj)
    External ({{ec_path}}.FANS, FieldUnitObj)
    External ({{ec_path}}.FA2S, FieldUnitObj)
    External ({{ec_path}}.CPUT, FieldUnitObj)
    External ({{ec_path}}.GPUT, FieldUnitObj)
    External ({{ec_path}}.{{lighting_owner_field}}, FieldUnitObj)
    Scope ({{ec_path}})
    {
        Method (RYLO, 0, Serialized) { Return ({{lighting_owner_field}}) }
        Method (RYBV, 0, Serialized) { Return ({{battery_mapping_version}}) }
        Method (RYCM, 0, Serialized) { Return ({{battery_conservation_mask}}) }
        Method (RYRM, 0, Serialized) { Return ({{battery_rapidcharge_mask}}) }
        Method (RYQC, 0, Serialized) { Return ({{battery_conservation_capability_mask}}) }
        Method (RYQR, 0, Serialized) { Return ({{battery_rapidcharge_capability_mask}}) }
        Method (RYCO, 0, Serialized) { Return ({{battery_conservation_on}}) }
        Method (RYCF, 0, Serialized) { Return ({{battery_conservation_off}}) }
        Method (RYRO, 0, Serialized) { Return ({{battery_rapidcharge_on}}) }
        Method (RYRF, 0, Serialized) { Return ({{battery_rapidcharge_off}}) }
        Method (RYVW, 0, Serialized) { Return ({{verified_writes}}) }
        Method (RYID, 0, Serialized) { Return (0x52590101) }
        Method (RYPN, 0, Serialized) { Return ("{{id}}") }
        Method (RYNM, 0, Serialized) { Return ("{{profile_name}}") }
        Method (RYF0, 0, Serialized) { Return (FANS * {{rpm_scale}}) }
        Method (RYF1, 0, Serialized) { Return (FA2S * {{rpm_scale}}) }
        Method (RYT0, 0, Serialized) { Return (CPUT) }
        Method (RYT1, 0, Serialized) { Return (GPUT) }
    }
}
