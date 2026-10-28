//
//  DefaultEvents.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 10/17/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation

private let commandFlag = UInt32(NSEvent.ModifierFlags.command.rawValue)
private let controlFlag = UInt32(NSEvent.ModifierFlags.control.rawValue)
private let optionFlag = UInt32(NSEvent.ModifierFlags.option.rawValue)

let ideaEvents: [UInt32: [UInt32: EventDescriptor]] = [
    0x00: [
        0x00: EventDescriptor("Special Button", display: false),
        0x01: EventDescriptor("Fn-Q Cooling", act: .thermal),
        0x02: EventDescriptor("ReYogaSMC Controls", .kStar, act: .controls),
        0x40: EventDescriptor("Fn-Q Cooling", act: .thermal)
    ],
    0x01: [0: EventDescriptor("Keyboard Backlight", act: .backlight)],
    0x02: [
        0: EventDescriptor("Screen Off"),
        1: EventDescriptor("Screen On")
    ],
    0x04: [0: EventDescriptor("Backlight Changed", display: false)],
    0x05: [
        0: EventDescriptor("TouchPad Off"),
        1: EventDescriptor("TouchPad On")
    ],
    0x06: [0: EventDescriptor("Display Settings", act: .displaysettings)],
    0x07: [
        0: EventDescriptor("Camera", .kCamera, act: .camera),
        optionFlag: EventDescriptor("Photo Booth", act: .launchapp, display: false, opt: "Photo Booth")
    ],
    0x08: [0: EventDescriptor("Mic Mute", act: .micmute)],
    0x0A: [0: EventDescriptor("TouchPad On")],
    0x0C: [0: EventDescriptor("Keyboard Backlight", act: .backlight)],
    0x0D: [
        0: EventDescriptor("Airplane Mode", act: .airplane),
        controlFlag: EventDescriptor("Bluetooth", act: .bluetooth),
        optionFlag: EventDescriptor("BT Discoverable", act: .bluetoothdiscoverable),
        commandFlag: EventDescriptor("Wireless", act: .wireless)
    ],
    0x10: [
        0: EventDescriptor("Yoga Mode", act: .yoga),
        1: EventDescriptor("Laptop Mode"),
        2: EventDescriptor("Tablet Mode"),
        3: EventDescriptor("Stand Mode"),
        4: EventDescriptor("Tent Mode")
    ],
    0x11: [0: EventDescriptor("FnLock", act: .fnlock)]
]

let thinkEvents: [UInt32: [UInt32: EventDescriptor]] = [
    TP_HKEY_EV_SLEEP.rawValue: [
        0: EventDescriptor("Sleep", act: .sleep, display: false),
        optionFlag: EventDescriptor("Sleep", act: .sleep)
    ], // 0x1004
    TP_HKEY_EV_NETWORK.rawValue: [
        0: EventDescriptor("Wireless", act: .wireless),
        optionFlag: EventDescriptor("Airplane Mode", act: .airplane)
    ], // 0x1005
    TP_HKEY_EV_DISPLAY.rawValue: [0: EventDescriptor("Second Display", .kSecondDisplay, act: .mirror)], // 0x1007
    TP_HKEY_EV_BRGHT_UP.rawValue: [0: EventDescriptor("Brightness Up", display: false)], // 0x1010
    TP_HKEY_EV_BRGHT_DOWN.rawValue: [0: EventDescriptor("Brightness Down", display: false)], // 0x1011
    TP_HKEY_EV_KBD_LIGHT.rawValue: [0: EventDescriptor("Keyboard Backlight", act: .backlight)], // 0x1012
    TP_HKEY_EV_MIC_MUTE.rawValue: [0: EventDescriptor("Mic Mute", act: .micmute)], // 0x101B
    TP_HKEY_EV_SETTING.rawValue: [0: EventDescriptor("Settings", act: .systemsettings, display: false)],
    TP_HKEY_EV_SEARCH.rawValue: [0: EventDescriptor("Search", act: .siri, display: false)],
    TP_HKEY_EV_MISSION.rawValue: [0: EventDescriptor("Mission Control", act: .mission, display: false)],
    TP_HKEY_EV_APPS.rawValue: [0: EventDescriptor("Launchpad", act: .launchpad, display: false)],
    TP_HKEY_EV_STAR.rawValue: [
        0: EventDescriptor("ReYogaSMC Controls", .kStar, act: .controls),
        optionFlag: EventDescriptor("System Preferences", .kStar, act: .launchbundle, opt: "com.apple.systempreferences")
    ],
    TP_HKEY_EV_BLUETOOTH.rawValue: [
        0: EventDescriptor("Bluetooth", act: .bluetooth),
        optionFlag: EventDescriptor("BT Discoverable", act: .bluetoothdiscoverable)
    ], // 0x1314
    TP_HKEY_EV_KEYBOARD.rawValue: [0: EventDescriptor("Keyboard Toggle", act: .keyboard)], // 0x1315
    TP_HKEY_EV_HOTPLUG_DOCK.rawValue: [0: EventDescriptor("Dock Attached", .kDock, display: true)], // 0x4010
    TP_HKEY_EV_HOTPLUG_UNDOCK.rawValue: [0: EventDescriptor("Dock Detached", .kUndock, display: true)], // 0x4011
    TP_HKEY_EV_LID_CLOSE.rawValue: [0: EventDescriptor("LID Close", display: false)], // 0x5001
    TP_HKEY_EV_LID_OPEN.rawValue: [0: EventDescriptor("LID Open", display: false)], // 0x5002
    TP_HKEY_EV_THM_TABLE_CHANGED.rawValue: [0: EventDescriptor("Thermal Table Change", display: false)], // 0x6030
    TP_HKEY_EV_THM_CSM_COMPLETED.rawValue: [0: EventDescriptor("Thermal Control Change", display: false)], // 0x6032
    TP_HKEY_EV_AC_CHANGED.rawValue: [0: EventDescriptor("AC Status Change", display: false)], // 0x6040
    TP_HKEY_EV_BACKLIGHT_CHANGED.rawValue: [0: EventDescriptor("Backlight Changed", display: false)], // 0x6050
    TP_HKEY_EV_KEY_FN_ESC.rawValue: [0: EventDescriptor("FnLock", act: .fnlock)], // 0x6060
    TP_HKEY_EV_PALM_DETECTED.rawValue: [0: EventDescriptor("Palm Detected", display: false)], // 0x60B0
    TP_HKEY_EV_PALM_UNDETECTED.rawValue: [0: EventDescriptor("Palm Undetected", display: false)], // 0x60B1
    TP_HKEY_EV_TABLET_CHANGED.rawValue: [
        0: EventDescriptor("Yoga Mode", act: .yoga),
        1: EventDescriptor("Laptop Mode"),
        2: EventDescriptor("Flat Mode"),
        3: EventDescriptor("Tablet Mode"),
        4: EventDescriptor("Stand Mode"),
        5: EventDescriptor("Tent Mode")
    ], // 0x60C0
    TP_HKEY_EV_THM_TRANSFM_CHANGED.rawValue: [0: EventDescriptor("Thermal Changed", display: false)] // 0x60F0
]

let HIDDEvents: [UInt32: [UInt32: EventDescriptor]] = [
    0x08: [
        0: EventDescriptor("Airplane Mode", act: .airplane),
        controlFlag: EventDescriptor("Bluetooth", act: .bluetooth),
        optionFlag: EventDescriptor("BT Discoverable", act: .bluetoothdiscoverable),
        commandFlag: EventDescriptor("Wireless", act: .wireless)
    ],
    0x0B: [
        0: EventDescriptor("Sleep", act: .sleep, display: false),
        optionFlag: EventDescriptor("Sleep", act: .sleep)
    ],
    0x0E: [0: EventDescriptor("STOPCD")],
    0xC8: [0: EventDescriptor("Rotate Lock")], // Down
    0xC9: [0: EventDescriptor("Rotate Lock", display: false)], // Up
    0xCC: [0: EventDescriptor("Convertible")], // Down
    0xCD: [0: EventDescriptor("Convertible", display: false)] // Up
]
