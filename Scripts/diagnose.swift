import Foundation
import IOKit
let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IdeaVPC"))
guard service != 0 else { fatalError("IdeaVPC unavailable") }
defer { IOObjectRelease(service) }
for _ in 0..<3 {
 let status = IORegistryEntrySetCFProperty(service, "Update" as CFString, kCFBooleanTrue)
 var snapshot: Unmanaged<CFMutableDictionary>?
 _ = IORegistryEntryCreateCFProperties(service, &snapshot, kCFAllocatorDefault, 0)
 let values = snapshot!.takeRetainedValue() as NSDictionary
 print("Update", status, ["Fan1RPM", "Fan2RPM", "CPUTemp", "GPUTemp", "RapidChargeMode", "SmartFanMode"].map { "\($0)=\(values[$0] ?? "missing")" }.joined(separator: " "))
 Thread.sleep(forTimeInterval: 2)
}
