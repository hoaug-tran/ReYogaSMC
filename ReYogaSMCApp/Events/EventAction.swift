//
//  EventAction.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 10/17/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation
import os.log

enum EventAction: String {
    case nothing, script, launchapp, launchbundle
    case airplane, wireless, bluetooth, bluetoothdiscoverable
    case settings, systemsettings, spotlight, search, siri, sleep, micmute
    case mission, launchpad, desktop, expose, controls, calculator, screenshot, displaysettings
    case mirror, camera, yoga
    case backlight, fnlock, keyboard, thermal
}

struct EventDescriptor {
    let name: String
    let image: NSString?
    let action: EventAction
    let display: Bool
    let option: String?

    init(_ name: String, _ img: String? = nil, act: EventAction = .nothing, display: Bool = true, opt: String? = nil) {
        self.name = name
        if let path = img {
            if path.hasPrefix("/") {
                self.image = path as NSString
            } else if let res = Bundle.main.path(forResource: path, ofType: nil) {
                self.image = res as NSString
            } else {
                os_log("Incompatible res path: %s", type: .error, path)
                self.image = nil
            }
        } else {
            self.image = nil
        }
        self.action = act
        self.display = display
        self.option = opt
    }

    init(_ name: String, _ image: EventImage, act: EventAction = .nothing, display: Bool = true, opt: String? = nil) {
        self.name = name
        if let path = Bundle.main.path(forResource: String(image.rawValue.dropFirst(1)), ofType: "pdf") {
            self.image = path as NSString
        } else {
            self.image = nil
        }
        self.action = act
        self.display = display
        self.option = opt
    }
}
