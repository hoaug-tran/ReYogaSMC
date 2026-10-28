//
//  EventPreferences.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 10/17/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation
import os.log

func loadEvents(_ events: inout [UInt32: [UInt32: EventDescriptor]], defaults: UserDefaults = ReYogaConstants.hardwareDefaults) {
    guard let dict = defaults.object(forKey: "Events") as? [String: Any] else {
        os_log("Events not found in preference, loading defaults", type: .info)
        return
    }

    for (sid, rawEntries) in dict {
        if let eid = UInt32(sid, radix: 16),
           let entries = rawEntries as? [String: Any] {
            var info = events[eid] ?? [:]
            for (sdata, entry) in entries {
                if let data = UInt32(sdata, radix: 16),
                   let event = entry as? [String: Any],
                   let name = event["name"] as? String,
                   let action = event["action"] as? String {
                    let opt = event["option"] as? String
                    if info[data] != nil,
                       action == "nothing",
                       (opt == "Unknown" || (opt == nil && name.hasPrefix("Event 0x"))) {
                        os_log("Override unknown event 0x%04x : %d", type: .info, eid, data)
                    } else {
                        var resolvedAction = EventAction(rawValue: action) ?? .nothing
                        if eid == TP_HKEY_EV_SETTING.rawValue && resolvedAction == .settings {
                            resolvedAction = .systemsettings
                        }
                        info[data] = EventDescriptor(
                            name,
                            event["image"] as? String,
                            act: resolvedAction,
                            display: (event["display"] as? Bool) ?? true,
                            opt: opt)
                    }
                } else {
                    os_log("Invalid event for 0x%04x : %s!", type: .info, eid, sdata)
                }
            }
            events[eid] = info
        } else {
            os_log("Invalid event %s!", type: .info, sid)
        }
    }
    os_log("Loaded %d events", type: .info, events.count)
}

func saveEvents(_ events: [UInt32: [UInt32: EventDescriptor]], defaults: UserDefaults = ReYogaConstants.hardwareDefaults) {
    var dict: [String: Any] = [:]
    for (eid, info) in events {
        var events: [String: Any] = [:]
        for (data, desc) in info {
            var event: [String: Any] = [:]
            event["name"] = desc.name
            if let res = desc.image {
                if let path = Bundle.main.resourcePath,
                   res.hasPrefix(path) {
                    event["image"] = res.lastPathComponent
               } else {
                    event["image"] = res
               }
            }
            event["action"] = desc.action.rawValue
            event["display"] = desc.display
            if desc.option != nil {
                event["option"] = desc.option
            }
            events[String(data, radix: 16)] = event
        }
        dict[String(eid, radix: 16)] = events
    }
    defaults.setValue(dict, forKey: "Events")
}

func resetDefaultEvents(_ events: inout [UInt32: [UInt32: EventDescriptor]], ioClass: String,
                        defaults: UserDefaults = ReYogaConstants.hardwareDefaults) {
    defaults.removeObject(forKey: "Events")
    switch ioClass {
    case "IdeaVPC":
        events = ideaEvents
    case "ThinkVPC":
        events = thinkEvents
    case "ReYogaHIDD":
        events = HIDDEvents
    default:
        break
    }
}
