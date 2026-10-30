import Foundation

public struct HardwareFeatureStatus: Equatable {
    public let available: Bool
    public let reason: String
    public let backend: String
    public static let catalog: [String: String] = [
        "ChargeStartThreshold": "Charge Start", "ChargeStopThreshold": "Charge Stop", "BatteryIndex": "Battery",
        "SmartFanMode": "Power Profile", "ConservationMode": "Conservation", "RapidChargeMode": "Rapid Charge",
        "DisplayOverDrive": "Display Overdrive", "TouchpadLock": "Touchpad Lock",
        "AlwaysOnUSBState": "Always-On USB", "FnlockMode": "Fn Lock", "BacklightLevel": "Keyboard Backlight",
        "YLogoStatus": "Logo Lighting", "PortLighting": "Port Lighting", "FanFullSpeed": "Full Speed", "FanControlMode": "Manual Fan Control",
        "Fan1TargetRPM": "Fan 1 Minimum", "Fan2TargetRPM": "Fan 2 Minimum",
        "CPUBoostPower": "CPU Boost Power Limit", "CPUSustainedPower": "CPU Sustained Power Limit",
        "CPUPowerReset": "Reset CPU Power Limits", "GPUPowerLimit": "GPU Power Limit", "CPUOverclock": "CPU Overclock", "GPUOverclock": "GPU Overclock", "HybridGraphics": "Hybrid / Discrete Graphics"
    ]
}
