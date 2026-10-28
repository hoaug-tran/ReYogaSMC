// Copyright © 2020 Zhen. All rights reserved.

import AppKit
import os.log

private func applicationURL(_ name: String) -> URL? {
    let workspace = NSWorkspace.shared
    if let url = workspace.urlForApplication(withBundleIdentifier: name) { return url }
    if name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) { return URL(fileURLWithPath: name) }
    let filename = name.hasSuffix(".app") ? name : name + ".app"
    let directories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                       URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                       URL(fileURLWithPath: "/System/Applications/Utilities"),
                       URL(fileURLWithPath: "/System/Library/CoreServices/Applications")]
    return directories.map { $0.appendingPathComponent(filename) }.first { FileManager.default.fileExists(atPath: $0.path) }
}

func dispatchDriverEvent(_ notification: SMCNotificationMessage, context: DriverEventContext) {
    if let events = context.events[notification.event] {
        let mod = context.modifier.subtracting(.capsLock)
        if !mod.isEmpty,
           let desc = events[notification.data | UInt32(mod.rawValue)] {
            eventActuator(desc, notification.data, context)
        } else if let desc = events[notification.data] {
            eventActuator(desc, notification.data, context)
        } else if let desc = events[0] {
            eventActuator(desc, notification.data, context)
        } else {
            let value = String(format: "0x%04x:%d", notification.event, notification.data)
            showOSDRaw("\(loc(.eventPrefix))\(value)")
            os_log("Event %s default data not found", type: .error, value)
        }
    } else {
        let value = String(format: "0x%04x:%d", notification.event, notification.data)
        showOSDRaw("\(loc(.eventPrefix))\(value)")
        context.events[notification.event] = [0: EventDescriptor(localizedMessage("Event %@", value), nil, opt: "Unknown")]
        #if DEBUG
        os_log("Event %s", type: .debug, value)
        #endif
    }
}

func eventActuator(_ desc: EventDescriptor, _ data: UInt32, _ context: DriverEventContext) {
    switch desc.action {
    case .nothing:
        #if DEBUG
        os_log("%s: Do nothing", type: .info, desc.name)
        #endif
        if !desc.display { return }
        if desc.name.hasPrefix("Event ") {
            let prompt = loc(.eventPrefix) + desc.name.dropFirst("Event ".count)
            showOSDRaw(prompt, desc.image)
        } else {
            showOSD(desc.name, desc.image)
        }
    case .script:
        if let scpt = desc.option {
            _ = scriptHelper(scpt, desc.name, desc.display ? desc.image : nil)
        } else {
            os_log("%s: script not found", type: .error, desc.name)
        }
    case .launchapp:
        guard let name = desc.option,
              let url = applicationURL(name) else {
            os_log("%s: app name not found", type: .error, desc.name)
            return
        }
        launchApplication(at: url, title: desc.name, image: desc.image, display: desc.display)
    case .launchbundle:
        guard let identifier = desc.option else {
            os_log("%s: bundle not found", type: .error)
            return
        }
        let collection = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        if collection.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                os_log("%s: app url not found", type: .error, desc.name)
                return
            }
            launchApplication(at: url, title: desc.name, display: false)
        } else {
            var hide = false
            for app in collection where !app.isHidden {
                hide = true
                break
            }
            for app in collection {
                if hide {
                    app.hide()
                } else {
                    app.activate(options: .activateIgnoringOtherApps)
                }
            }
            if hide { return }
        }
        if desc.display { showOSD(desc.name, desc.image) }
    case .airplane:
        airplaneModeHelper(desc.name, desc.display)
    case .bluetooth:
        bluetoothHelper(desc.name, desc.display)
    case .bluetoothdiscoverable:
        bluetoothDiscoverableHelper(desc.name, desc.display)
    case .backlight:
        if !desc.display { return }
        if getNumber("BacklightLevel", context.service) < 0 && getBoolean("LenovoLightingMethod", context.service) {
            showOSDRaw("Keyboard lighting changed")
            return
        }
        if (data & 0x10 != 0) { return }
        switch data & 0x0f {
        case 0:
            showOSDRes("Keyboard Backlight", "Off", .kBacklightOff)
        case 1:
            showOSDRes("Keyboard Backlight", "Low", .kBacklightLow)
        case 2:
            showOSDRes("Keyboard Backlight", "High", .kBacklightHigh)
        default:
            showOSDRes("Keyboard Backlight", "\(data)", .kBacklightHigh)
        }
    case .fnlock:
        if !desc.display { return }
        switch data {
        case 0:
            showOSDRes("Fn Lock", "Media keys", .kFunctionKeyOff)
        case 1:
            showOSDRes("Fn Lock", "F1–F12 keys", .kFunctionKeyOn)
        default:
            // Reserved values belong to firmware-defined media keyboard states.
            showOSDRes("Fn Lock", "\(data)", .kFunctionKeyOn)
        }
    case .keyboard:
        if !desc.display { return }
        showOSDRes("Keyboard", (data != 0) ? "Enabled" : "Disabled", (data != 0) ? .kKeyboard : .kKeyboardOff)
    case .micmute:
        micMuteHelper(context.service, desc.name)
    case .desktop, .expose, .mission, .launchpad:
        performDesktopAction(desc.action)
    case .settings:
        context.showSettings?()
    case .systemsettings:
        let opened = URL(string: "x-apple.systempreferences:").map { NSWorkspace.shared.open($0) } ?? false
        if !opened, let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            launchApplication(at: appUrl, title: desc.name, display: false)
        }
    case .sleep:
        if desc.display {
            showOSDRes(desc.name, .kSleep)
            sleep(1)
        }
        _ = scriptHelper(sleepAS, desc.name)
    case .search:
        _ = scriptHelper(searchAS, desc.name)
    case .spotlight:
        _ = scriptHelper(spotlightAS, desc.name)
    case .controls:
        context.toggleControls?()
    case .calculator, .screenshot, .siri:
        let bundle = desc.action == .siri ? "com.apple.Siri" : desc.action == .calculator ? "com.apple.calculator" : "com.apple.Screenshot"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            launchApplication(at: url, title: desc.name, image: desc.image, display: desc.display)
        } else { showOSDRaw(localizedMessage("%@: application unavailable", desc.name)) }
    case .displaysettings, .mirror:
        performDesktopAction(desc.action, title: desc.display ? "Display Settings" : nil)
    case .thermal:
        context.refreshHardware?()
        showOSD(desc.name, desc.image)
        os_log("%s: thermal event", type: .info, desc.name)
    case .wireless:
        wirelessHelper(desc.name, desc.display)
    default:
        #if DEBUG
        os_log("%s: Not implmented", type: .info, desc.name)
        #endif
        if desc.display {
            showOSD(desc.name, desc.image)
        }
    }
}
