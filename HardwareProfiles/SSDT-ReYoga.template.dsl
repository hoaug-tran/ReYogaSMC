// SPDX-License-Identifier: GPL-2.0-only
// ReYogaSMC ACPI bridge v2. Generated ONLY after matching a reviewed profile.
// Profile: {{profile_name}}
// Sensors/fan layout: LenovoLegionLinux model_v0 (GKCN, EC IT8227).
// Fan settings are MINIMUMS: each factory curve point can only be increased.
// Auto mode restores the original tables. No EC firmware/BIOS flashing.
DefinitionBlock ("", "SSDT", 2, "REYOGA", "RYLG", 0x00000001)
{
    External ({{ec_path}}, DeviceObj)
    External ({{ec_path}}.{{power_mode_field}}, FieldUnitObj)
    External ({{ec_path}}.{{fan_command_method}}, MethodObj)
    Scope ({{ec_path}})
    {
        OperationRegion (RYER, SystemMemory, {{ec_base}}, {{ec_size}})
        Field (RYER, ByteAcc, NoLock, Preserve)
        {
            Offset ({{curve_point}}), RYCP, 8, RYCS, 8,
            Offset ({{cpu_temp}}), RYCT, 8, RYGT, 8,
            Offset ({{fan1_rpm}}), RYR0, 16, RYR1, 16,
            Offset ({{update_counter1}}), RYC0, 8, RYC1, 8,
            Offset ({{internal_cpu_level}}), RYL0, 8, RYL1, 8, RYL2, 8
        }
        Field (RYER, BufferAcc, NoLock, Preserve)
        {
            Offset ({{fan1_curve}}), RYB0, 80,
            Offset ({{fan2_curve}}), RYB1, 80
        }
        Name (RYO0, Buffer (10) {})
        Name (RYO1, Buffer (10) {})
        Name (RYPM, 0xFFFF)
        Name (RYA0, Zero)
        Name (RYA1, Zero)
        Name (RYP0, Zero)
        Name (RYP1, Zero)
        // Preserve the result discarded by the firmware WMI dispatcher.
        // This is the same vendor full-speed command, not a fan-curve write.
        Method (RYFF, 1, Serialized)
        {
            If (Arg0 > One) { Return (0x02) }
            If (Arg0)
            {
                Return ({{fan_command_method}} ({{fan_fullspeed_command}}, {{fan_fullspeed_on}}))
            }
            Return ({{fan_command_method}} ({{fan_fullspeed_command}}, {{fan_fullspeed_off}}))
        }
        Method (RYLW, 0, Serialized) { Return ({{wmi_lighting_supported}}) }
        Method (RYVW, 0, Serialized) { Return ({{verified_writes}}) }
        Method (RYID, 0, Serialized) { Return (0x52590102) }
        Method (RYPN, 0, Serialized) { Return ("{{id}}") }
        Method (RYNM, 0, Serialized) { Return ("{{profile_name}}") }
        Method (RYF0, 0, Serialized) { Return (RYR0) }
        Method (RYF1, 0, Serialized) { Return (RYR1) }
        Method (RYT0, 0, Serialized) { Return (RYCT) }
        Method (RYT1, 0, Serialized) { Return (RYGT) }
        Method (RYG0, 0, Serialized) { If (RYA0 && RYVF (RYB0, RYP0)) { Return (Zero) } Return (RYP0) }
        Method (RYG1, 0, Serialized) { If (RYA1 && RYVF (RYB1, RYP1)) { Return (Zero) } Return (RYP1) }
        Method (RYFM, 0, Serialized)
        {
            If ({{power_mode_field}} != RYPM) { RYFA () }
            Return (RYA0 | RYA1)
        }
        // Firmware fan-curve length is bounded to the reviewed ten points.
        Method (RYVF, 2, Serialized)
        {
            If ((RYCS == Zero) || (RYCS > {{curve_points_max}})) { Return (One) }
            Local0 = Zero
            While (Local0 < RYCS)
            {
                If ((DerefOf (Arg0 [Local0]) * {{rpm_scale}}) < Arg1) { Return (One) }
                Local0++
            }
            Return (Zero)
        }
        Method (RYRC, 0, Serialized)
        {
            // Same recomputation sequence as LenovoLegionLinux v0 EC writes.
            RYCP = Zero
            RYL0 = Zero
            RYL1 = Zero
            RYL2 = Zero
        }
        Method (RYMX, 1, Serialized)
        {
            Local0 = Zero
            Local1 = Zero
            While (Local0 < SizeOf (Arg0))
            {
                Local2 = DerefOf (Arg0 [Local0])
                If (Local2 > Local1) { Local1 = Local2 }
                Local0++
            }
            Return (Local1 * {{rpm_scale}})
        }
        Method (RYM0, 0, Serialized)
        {
            If (RYA0) { Return (RYMX (RYO0)) }
            Return (RYMX (RYB0))
        }
        Method (RYM1, 0, Serialized)
        {
            If (RYA1) { Return (RYMX (RYO1)) }
            Return (RYMX (RYB1))
        }
        Method (RYFS, 2, Serialized)
        {
            If (!RYVW ()) { Return (One) }
            If ((Arg0 > One) || (RYCS == Zero) || (RYCS > {{curve_points_max}})) { Return (One) }
            If ({{power_mode_field}} != RYPM) { RYFA () }
            RYPM = {{power_mode_field}}
            If (Arg0 == Zero) { Local4 = RYM0 () }
            Else { Local4 = RYM1 () }
            If ((Local4 == Zero) || (Arg1 > Local4)) { Return (One) }
            If (Arg0 == Zero)
            {
                If (!RYA0) { RYO0 = RYB0 }
                RYA0 = One
                RYP0 = Arg1
                Local0 = RYO0
            }
            Else
            {
                If (!RYA1) { RYO1 = RYB1 }
                RYA1 = One
                RYP1 = Arg1
                Local0 = RYO1
            }
            Divide (Arg1, {{rpm_scale}}, Local1, Local2)
            If (Local1) { Local2++ }
            Local3 = Zero
            While (Local3 < RYCS)
            {
                // Only active points are modified; never lower a factory point.
                Local4 = DerefOf (Local0 [Local3])
                If (Local4 < Local2) { Local0 [Local3] = Local2 }
                Local3++
            }
            RYC0 = Zero
            RYC1 = Zero
            If (Arg0 == Zero) { RYB0 = Local0 }
            Else { RYB1 = Local0 }
            RYRC ()
            If (Arg0 == Zero) { Return (RYVF (RYB0, Arg1)) }
            Return (RYVF (RYB1, Arg1))
        }
        Method (RYFA, 0, Serialized)
        {
            // A profile switch already installed a new factory curve: discard
            // the old backup instead of restoring it into the new profile.
            If ({{power_mode_field}} == RYPM)
            {
                If (RYA0) { RYB0 = RYO0 }
                If (RYA1) { RYB1 = RYO1 }
                If (RYA0 || RYA1) { RYRC () }
            }
            RYA0 = Zero
            RYA1 = Zero
            RYP0 = Zero
            RYP1 = Zero
            Return (Zero)
        }
    }
}
