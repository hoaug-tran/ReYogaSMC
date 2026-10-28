#if DEBUG
import Foundation
import IOKit

struct HardwarePreviewSnapshot {
    let properties: NSDictionary
    let liveBattery: LiveBatterySnapshot?
    let batteryDetails: [BatteryDetail]
    let cpu: SMCTemperatureReader.Reading?
    let gpu: SMCTemperatureReader.Reading?

    private init(properties: NSDictionary, liveBattery: LiveBatterySnapshot?,
                 cpu: SMCTemperatureReader.Reading? = nil, gpu: SMCTemperatureReader.Reading? = nil) {
        self.properties = properties
        self.liveBattery = liveBattery
        self.cpu = cpu
        self.gpu = gpu
        batteryDetails = (0...1).compactMap { index in
            guard let values = properties["Battery \(index)"] as? [String: Any] else { return nil }
            let detail = BatteryDetail(index: index, properties: values)
            return detail.present ? detail : nil
        }
    }

    static func fixture(_ properties: NSDictionary) -> HardwarePreviewSnapshot {
        HardwarePreviewSnapshot(properties: properties,
            liveBattery: (properties["AppleSmartBattery"] as? [String: Any]).map { LiveBatterySnapshot(properties: $0) })
    }

    static func readOnly(_ service: io_service_t, temperatures: SMCTemperatureReader) -> HardwarePreviewSnapshot? {
        guard let properties = getProperties(service) else { return nil }
        let cpu = temperatures.cpuTemperature()
        let gpu = temperatures.gpuTemperature()
        return HardwarePreviewSnapshot(properties: properties, liveBattery: LiveBatterySnapshot.read(), cpu: cpu, gpu: gpu)
    }
}
#endif
