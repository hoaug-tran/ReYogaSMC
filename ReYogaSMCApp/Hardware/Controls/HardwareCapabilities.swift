import Foundation

struct HardwareCapabilities {
    let features: [String: HardwareFeatureStatus]
    let powerRanges: [String: [String: Int]]
    let fanStepsRPM: [Int]
    let conservationMask: Int?
    let rapidChargeMask: Int?
    let conservationState: Bool?
    let rapidChargeState: Bool?

    init(_ props: NSDictionary, rgbStatus: HardwareFeatureStatus, rgbMode: String, sampleIsStale: Bool,
         profiles: [[String: Any]] = HardwareProfiles.all()) {
        let descriptors = (props["FeatureStatus"] as? [String: [String: Any]]) ?? [:]
        let providerClass = (props["IOClass"] as? String) ?? ""
        let protocolVersion = (props["ControlProtocolVersion"] as? Int) ?? 0
        var conservationState: Bool?
        var rapidChargeState: Bool?
        var availability: [String: HardwareFeatureStatus] = [:]
        for key in HardwareFeatureStatus.catalog.keys {
            if let item = descriptors[key] {
                availability[key] = HardwareFeatureStatus(available: item["Available"] as? Bool == true,
                    reason: (item["Reason"] as? String) ?? "Driver did not provide a reason",
                    backend: (item["Backend"] as? String) ?? "Unknown")
            } else {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: protocolVersion == 0 ? "Boot the matching ReYogaSMC driver to verify support" : "No backend for this device",
                    backend: "Unavailable")
            }
        }
        if providerClass == "IdeaVPC" {
            for key in ["FanControlMode", "Fan1TargetRPM", "Fan2TargetRPM"] {
                availability[key] = HardwareSnapshot.manualFanFeature(availability[key], key: key,
                    bridgeVersion: (props["ACPIBridgeVersion"] as? Int) ?? 0,
                    writesValidated: props["FanWritesValidated"] as? Bool == true)
            }
        }
        let stateControls = ["SmartFanMode", "ConservationMode", "RapidChargeMode", "AlwaysOnUSBState", "FnlockMode", "BacklightLevel", "DisplayOverDrive", "TouchpadLock", "YLogoStatus", "PortLighting", "CPUBoostPower", "CPUSustainedPower", "FanControlMode", "Fan1TargetRPM", "Fan2TargetRPM"]
        for key in stateControls where availability[key]?.available == true && props[key] == nil {
            availability[key] = HardwareFeatureStatus(available: false,
                reason: "The driver did not provide a current value for this control.", backend: availability[key]?.backend ?? "Unavailable")
        }
        for (key, range) in ["SmartFanMode": 1...3, "BacklightLevel": 0...2, "AlwaysOnUSBState": 0...2,
                             "FanControlMode": 0...1, "ChargeStartThreshold": 0...99,
                             "ChargeStopThreshold": 1...100, "BatteryIndex": 1...2] where availability[key]?.available == true {
            if HardwareSnapshot.integer(props[key]).map({ range.contains($0) }) != true {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: "The driver did not provide a valid current value for this control.", backend: availability[key]?.backend ?? "Unavailable")
            }
        }
        let reportedRanges = (props["PowerLimitRanges"] as? [String: Any]) ?? [:]
        var validatedRanges: [String: [String: Int]] = [:]
        for key in ["CPUBoostPower", "CPUSustainedPower"] {
            if let range = HardwareSnapshot.powerRange(reportedRanges[key], current: props[key]) {
                validatedRanges[key] = range
            } else if availability[key]?.available == true {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: "The driver did not provide a valid current power limit and adjustment range.", backend: availability[key]?.backend ?? "Unavailable")
            }
        }
        let fanSteps = [HardwareSnapshot.integer(props["Fan1TargetRPMStep"]) ?? 0, HardwareSnapshot.integer(props["Fan2TargetRPMStep"]) ?? 0]
        for (index, key) in ["Fan1TargetRPM", "Fan2TargetRPM"].enumerated() where availability[key]?.available == true {
            let maximum = HardwareSnapshot.fanRPM(props[index == 0 ? "Fan1MaxRPM" : "Fan2MaxRPM"])
            let current = HardwareSnapshot.fanRPM(props[key])
            if maximum <= 0 || current < 0 || current > maximum || fanSteps[index] <= 0 || fanSteps[index] > maximum {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: "The driver did not provide a valid fan adjustment range and step.", backend: availability[key]?.backend ?? "Unavailable")
            }
        }
        if rgbStatus.available && rgbMode != "Factory" {
            availability["YLogoStatus"] = HardwareFeatureStatus(available: true,
                reason: "USB transmission only; the device does not report the physical LED state", backend: "USB HID")
        }
        let batteryProfile = profiles.first { $0["id"] as? String == props["HardwareProfile"] as? String }
        let conservationMask = batteryProfile?["battery_conservation_mask"] as? Int
        let rapidMask = batteryProfile?["battery_rapidcharge_mask"] as? Int
        if let conservationMask = conservationMask, let rapidMask = rapidMask {
            let mappingMatches = [1, 4].contains((props["BatteryStateSchemaVersion"] as? Int) ?? 0) &&
                props["ConservationStateMask"] as? Int == conservationMask && props["RapidChargeStateMask"] as? Int == rapidMask
            if mappingMatches {
                if let raw = props["BatteryModeRaw"] as? Int {
                    conservationState = raw & conservationMask != 0
                    rapidChargeState = raw & rapidMask != 0
                }
            }
            if !mappingMatches {
                for key in ["ConservationMode", "RapidChargeMode"] {
                    availability[key] = HardwareFeatureStatus(available: false,
                        reason: "The driver battery-state masks do not match the reviewed firmware profile", backend: "ACPI profile")
                }
            }
        }
        if sampleIsStale {
            for key in availability.keys where availability[key]?.available == true && availability[key]?.backend != "USB HID" {
                availability[key] = HardwareFeatureStatus(available: false,
                    reason: "The driver snapshot is stale. Refresh the connection before changing firmware controls.",
                    backend: availability[key]?.backend ?? "Unavailable")
            }
        }
        features = availability
        powerRanges = validatedRanges
        fanStepsRPM = fanSteps
        self.conservationMask = conservationMask
        rapidChargeMask = rapidMask
        self.conservationState = conservationState
        self.rapidChargeState = rapidChargeState
    }
}
