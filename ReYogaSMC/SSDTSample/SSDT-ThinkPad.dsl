DefinitionBlock ("", "SSDT", 2, "hack", "ThinkPad", 0x00000000)
{
    External (_SB.PCI0.LPCB.EC, DeviceObj)
    External (_SB.PCI0.LPCB.EC.HKEY, DeviceObj)
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
                Arg1 = ((Arg1 + 0x07) >> 0x03)
                Name (TEMP, Buffer (Arg1) {})
                Arg1 += Arg0
                Local0 = Zero
                While ((Arg0 < Arg1))
                {
                    TEMP [Local0] = RE1B (Arg0)
                    Arg0++
                    Local0++
                }

                Return (TEMP)
            }

            Method (WECB, 3, Serialized)
            {
                Arg1 = ((Arg1 + 0x07) >> 0x03)
                Name (TEMP, Buffer (Arg1) {})
                TEMP = Arg2
                Arg1 += Arg0
                Local0 = Zero
                While ((Arg0 < Arg1))
                {
                    WE1B (Arg0, DerefOf (TEMP [Local0]))
                    Arg0++
                    Local0++
                }
            }

            OperationRegion (ESEN, EmbeddedControl, Zero, 0x0100)
            Field (ESEN, ByteAcc, NoLock, Preserve)
            {
                Offset (0x78), 
                EST0, 8, 
                EST1, 8, 
                EST2, 8, 
                EST3, 8, 
                EST4, 8, 
                EST5, 8, 
                EST6, 8, 
                EST7, 8, 
                Offset (0xC0), 
                EST8, 8, 
                EST9, 8, 
                ESTA, 8, 
                ESTB, 8, 
                ESTC, 8, 
                ESTD, 8, 
                ESTE, 8, 
                ESTF, 8
            }
        }
    }
}
