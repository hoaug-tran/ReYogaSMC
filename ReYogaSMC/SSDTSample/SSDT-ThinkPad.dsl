// Generated from HardwareProfiles/SSDT-ThinkPad.template.dsl; adapt paths to the target DSDT.
// EC thermal offsets are firmware-specific; sensor fields are not added here.
DefinitionBlock ("", "SSDT", 2, "hack", "ThinkPad", 0x00000000)
{
    External (\_SB.PCI0.LPCB.EC, DeviceObj)
    External (\_SB.PCI0.LPCB.EC.HKEY, DeviceObj)
    External (_SI_._SST, MethodObj)
    External (LNUX, IntObj)
    External (WNTF, IntObj)

    If (_OSI ("Darwin"))
    {
        If (CondRefOf (\LNUX))
        {
            \LNUX = 0x01
        }

        If (CondRefOf (\WNTF))
        {
            \WNTF = 0x01
        }

        Scope (\_SB.PCI0.LPCB.EC.HKEY)
        {
            Method (CSSI, 1, NotSerialized)
            {
                If (CondRefOf (\_SI_._SST))
                {
                    \_SI_._SST (Arg0)
                }
            }
        }

        Scope (\_SB.PCI0.LPCB.EC)
        {
            Method (RE1B, 1, Serialized)
            {
                OperationRegion (ERAM, EmbeddedControl, Arg0, One)
                Field (ERAM, ByteAcc, NoLock, Preserve)
                {
                    BYTE, 8
                }

                Return (BYTE)
            }

            Method (WE1B, 2, Serialized)
            {
                OperationRegion (ERAM, EmbeddedControl, Arg0, One)
                Field (ERAM, ByteAcc, NoLock, Preserve)
                {
                    BYTE, 8
                }

                BYTE = Arg1
            }

            Method (RECB, 2, Serialized)
            {
                Local0 = ((Arg1 + 0x07) >> 0x03)
                Name (TEMP, Buffer (Local0) {})
                Local1 = Zero
                While ((Local1 < Local0))
                {
                    TEMP [Local1] = RE1B ((Arg0 + Local1))
                    Local1++
                }

                Return (TEMP)
            }

            Method (WECB, 3, Serialized)
            {
                Local0 = ((Arg1 + 0x07) >> 0x03)
                Name (TEMP, Buffer (Local0) {})
                TEMP = Arg2
                Local1 = Zero
                While ((Local1 < Local0))
                {
                    WE1B ((Arg0 + Local1), DerefOf (TEMP [Local1]))
                    Local1++
                }
            }
        }
    }
}
