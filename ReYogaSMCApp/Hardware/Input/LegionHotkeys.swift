import AppKit
import Foundation
import IOKit
import IOKit.hid
import ApplicationServices

final class LegionHotkeys {
    // Injected media events must not be remapped as physical keys.
    static let syntheticEventTag: Int64 = 0x52594b
    private var generation: UInt64 = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var manager: IOHIDManager?
    private var mapping: [String: String] = [:]
    private var consumer: [String: String] = [:]
    private var printKeys: [Int] = []
    private var physicalFnKeycode: Int?
    private var physicalFnDown = false
    private var consumedKeys: Set<Int> = []
    private var repeatableActions: Set<String> = []
    static func rawAction(keycode: Int, physicalFnDown: Bool, mapping: [String: String]) -> String? {
        physicalFnDown ? mapping[String(keycode)] : nil
    }
    var action: ((String) -> Void)?
    func start(profileID: String) throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw SupportError.message("Enable Accessibility for ReYogaSMC to map Fn hotkeys")
        }
        guard let profile = HardwareProfiles.hotkeys(for: profileID) else { throw SupportError.message("No hotkey profile available") }
        mapping = (profile["keycodes"] as? [String: String]) ?? [:]
        consumer = (profile["consumerUsages"] as? [String: String]) ?? [:]
        printKeys = (profile["printScreenKeycodes"] as? [Int]) ?? []
        physicalFnKeycode = profile["physicalFnKeycode"] as? Int
        repeatableActions = Set((profile["repeatableActions"] as? [String]) ?? [])
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<LegionHotkeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == LegionHotkeys.syntheticEventTag { return Unmanaged.passUnretained(event) }
                let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if type == .flagsChanged {
                    if key == controller.physicalFnKeycode { controller.physicalFnDown = event.flags.contains(.maskSecondaryFn) }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyUp && controller.consumedKeys.remove(key) != nil { return nil }
                let mapped = controller.printKeys.contains(key) ? "screenshot" :
                    LegionHotkeys.rawAction(keycode: key, physicalFnDown: controller.physicalFnDown, mapping: controller.mapping)
                guard let action = mapped else {
                    if UserDefaults.standard.bool(forKey: "DetailedLogging") && (event.flags.contains(.maskSecondaryFn) || controller.mapping[String(key)] != nil) {
                        ReYogaDiagnostics.shared.record("unmapped_key", ["keycode": key, "flags": event.flags.rawValue, "type": type.rawValue])
                    }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    controller.consumedKeys.insert(key)
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || controller.repeatableActions.contains(action) {
                        controller.enqueueAction(action)
                    }
                }
                return nil
            }, userInfo: context), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { throw SupportError.message("macOS denied the hotkey event tap") }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == 0, let context = context, IOHIDValueGetIntegerValue(value) != 0 else { return }
            let controller = Unmanaged<LegionHotkeys>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_Consumer) else { return }
            let usage = IOHIDElementGetUsage(element)
            guard usage > 0, usage <= 0xffff else { return }
            ReYogaDiagnostics.shared.record("consumer_key", ["usage": usage])
            if let action = controller.consumer[String(usage)] { controller.enqueueAction(action) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        if opened != kIOReturnSuccess {
            stop()
            throw SupportError.message(String(format: localizedMessage("Consumer hotkeys unavailable (0x%08x); check Input Monitoring permission"), opened))
        }
        ReYogaDiagnostics.shared.record("hotkeys_started", ["profile": profile["id"] ?? "unknown", "consumerStatus": opened])
    }
    private func enqueueAction(_ action: String) {
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.tap != nil, generation == self.generation else { return }
            self.action?(action)
        }
    }

    func stop() {
        generation &+= 1
        if let tap = tap { CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        tap = nil; source = nil; manager = nil
        physicalFnDown = false
        consumedKeys.removeAll()
    }
    deinit { stop() }
}
