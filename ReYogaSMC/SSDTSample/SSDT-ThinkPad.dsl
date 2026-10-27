// Update EC and HKEY paths to match the ACPI namespace before compiling.
// EC thermal offsets are firmware-specific; sensor fields are not added here.
DefinitionBlock ("", "SSDT", 2, "hack", "ThinkPad", 0x00000000)
{
    External (\_SB.PCI0.LPCB.EC, DeviceObj)
    External (\_SB.PCI0.LPCB.EC.HKEY, DeviceObj)
    External (_SI_._SST, MethodObj)
    External (LNUX, IntObj)
    External (WNTF, IntObj)
    External (\_SB.PCI0.LPCB.EC.HKEY.CSSI, MethodObj, UnknownObj, {IntObj})
    External (\_SB.PCI0.LPCB.EC.RE1B, MethodObj, IntObj, {IntObj})
    External (\_SB.PCI0.LPCB.EC.WE1B, MethodObj, UnknownObj, {IntObj, IntObj})
    External (\_SB.PCI0.LPCB.EC.RECB, MethodObj, BuffObj, {IntObj, IntObj})
    External (\_SB.PCI0.LPCB.EC.WECB, MethodObj, UnknownObj, {IntObj, IntObj, BuffObj})

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
    }

    Scope (\_SB.PCI0.LPCB.EC.HKEY)
    {
        If (!CondRefOf (CSSI))
        {
            Method (CSSI, 1, NotSerialized)
            {
                If (CondRefOf (\_SI_._SST))
                {
                    \_SI_._SST (Arg0)
                }
            }
        }
    }

    Scope (\_SB.PCI0.LPCB.EC)
    {
        If (!CondRefOf (RE1B))
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
        }

        If (!CondRefOf (WE1B))
        {
            Method (WE1B, 2, Serialized)
            {
                OperationRegion (ERAM, EmbeddedControl, Arg0, One)
                Field (ERAM, ByteAcc, NoLock, Preserve)
                {
                    BYTE, 8
                }

                BYTE = Arg1
            }
        }

        If (!CondRefOf (RECB))
        {
            Method (RECB, 2, Serialized)
            {
                Local0 = ((Arg1 + 0x07) >> 0x03)
                Local2 = Buffer (Local0) {}
                Local1 = Zero
                While ((Local1 < Local0))
                {
                    Local2 [Local1] = RE1B ((Arg0 + Local1))
                    Local1++
                }

                Return (Local2)
            }
        }

        If (!CondRefOf (WECB))
        {
            Method (WECB, 3, Serialized)
            {
                Local0 = ((Arg1 + 0x07) >> 0x03)
                Local2 = Buffer (Local0) {}
                Local2 = Arg2
                Local1 = Zero
                While ((Local1 < Local0))
                {
                    WE1B ((Arg0 + Local1), DerefOf (Local2 [Local1]))
                    Local1++
                }
            }
        }
    }
}
