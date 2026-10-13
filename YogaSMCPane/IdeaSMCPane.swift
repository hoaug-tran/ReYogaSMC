import AppKit
import Foundation

extension YogaSMCPane {
    @IBAction func vFnKeySet(_ sender: NSButton) {
        if !sendBoolean("FnlockMode", vFnKeyRadio.state == .on, service) {
            vFnKeyRadio.state = getBoolean("FnlockMode", service) ? .on : .off
        }
    }

    @IBAction func vAlwaysOnUSBModeSet(_ sender: NSButton) {
        if !sendBoolean("AlwaysOnUSBMode", vAlwaysOnUSBMode.state == .on, service) {
            vAlwaysOnUSBMode.state = getBoolean("AlwaysOnUSBMode", service) ? .on : .off
        }
    }

    @IBAction func vConservationModeSet(_ sender: NSButton) {
        if !sendBoolean("ConservationMode", vConservationMode.state == .on, service) {
            vConservationMode.state = getBoolean("ConservationMode", service) ? .on : .off
        }
    }

    @IBAction func vRapidChargeModeSet(_ sender: NSButton) {
        if !sendBoolean("RapidChargeMode", vRapidChargeMode.state == .on, service) {
            vRapidChargeMode.state = getBoolean("RapidChargeMode", service) ? .on : .off
        }
    }

    @IBAction func vSmartFanSet(_ sender: NSSegmentedControl) {
        _ = sendNumber("SmartFanMode", sender.selectedSegment + 1, service)
    }

    @IBAction func vOverDriveSet(_ sender: NSButton) {
        _ = sendNumber("DisplayOverDrive", sender.state == .on ? 1 : 0, service)
    }

    @IBAction func vWinKeySet(_ sender: NSButton) {
        _ = sendNumber("WinKeyLock", sender.state == .on ? 1 : 0, service)
    }

    @IBAction func vFullFanSet(_ sender: NSButton) {
        _ = sendBoolean("FanFullSpeed", sender.state == .on, service)
    }

    @IBAction func vYLogoSet(_ sender: NSButton) {
        _ = sendBoolean("YLogoStatus", sender.state == .on, service)
    }

    @IBAction func vPortLightingSet(_ sender: NSButton) {
        _ = sendBoolean("PortLighting", sender.state == .on, service)
    }

    @IBAction func vAlwaysOnUSBStateSet(_ sender: NSSegmentedControl) {
        _ = sendNumber("AlwaysOnUSBState", sender.selectedSegment, service)
    }

    func updateIdeaBattery(_ dict: NSDictionary) {
        vBatteryID.stringValue = dict["ID"] as? String ?? "Unknown"
        vCycleCount.stringValue = dict["Cycle count"] as? String ?? "Unknown"
        vBatteryTemperature.stringValue = dict["Temperature"] as? String ?? "Unknown"
        vMfgDate.stringValue = dict["Manufacture date"] as? String ?? "Unknown"
    }

    func updateIdeaCap(_ dict: NSDictionary) {
        if let val = dict["Camera"] as? Bool {
            vCamera.textColor = val ? NSColor.systemGreen : NSColor.systemGray
        }
        if let val = dict["Bluetooth"] as? Bool {
            vBluetooth.textColor = val ? NSColor.systemGreen : NSColor.systemGray
        }
        if let val = dict["Wireless"] as? Bool {
            vWireless.textColor = val ? NSColor.systemGreen : NSColor.systemGray
        }
        if let val = dict["3G"] as? Bool {
            vWWAN.textColor = val ? NSColor.systemGreen : NSColor.systemGray
        }
        if let val = dict["Graphics"] as? NSString {
            vGraphics.toolTip = val as String
            switch val {
            case "Intel":
                vGraphics.textColor = NSColor(red: 0/0xff, green: 0x71/0xff, blue: 0xc5/0xff, alpha: 1)
            case "AMD", "ATI", "Intel and ATI":
                vGraphics.textColor = NSColor(red: 0x97/0xff, green: 0x0a/0xff, blue: 0x1b/0xff, alpha: 1)
            case "Nvidia", "Intel and Nvidia":
                vGraphics.textColor = NSColor(red: 0x76/0xff, green: 0xb9/0xff, blue: 0/0xff, alpha: 1)
            default: break
            }
        }
    }

    func updateIdea(_ props: NSDictionary) {
        if let val = props["PrimeKeyType"] as? NSString {
            vFnKeyRadio.title = val as String
            if let val = props["FnlockMode"] as? Bool {
                vFnKeyRadio.isEnabled = true
                vFxKeyRadio.isEnabled = true
                if val {
                    vFnKeyRadio.state = .on
                } else {
                    vFxKeyRadio.state = .on
                }
            }
        } else {
            vFnKeyRadio.title = "Unknown"
        }

        if let val = props["AlwaysOnUSBMode"] as? Bool {
            vAlwaysOnUSBMode.state = val ? .on : .off
            vAlwaysOnUSBMode.isEnabled = true
        }

        if let val = props["ConservationMode"] as? Bool {
            vConservationMode.state = val ? .on : .off
            vConservationMode.isEnabled = true
        }

        if let val = props["RapidChargeMode"] as? Bool {
            vRapidChargeMode.state = val ? .on : .off
            vRapidChargeMode.isEnabled = true
        }

        if let dict = props["Battery 0"] as? NSDictionary {
            updateIdeaBattery(dict)
        }

        if let dict = props["Capability"] as? NSDictionary {
            updateIdeaCap(dict)
        }
    }
}
