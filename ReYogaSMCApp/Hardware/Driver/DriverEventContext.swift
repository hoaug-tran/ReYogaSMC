//
//  DriverEventContext.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 10/17/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation

final class DriverEventContext {
    var showSettings: (() -> Void)?
    var toggleControls: (() -> Void)?
    var refreshHardware: (() -> Void)?
    var notificationPort: CFMachPort?
    var notificationSource: CFRunLoopSource?
    var connect: io_connect_t = 0
    var events: [UInt32: [UInt32: EventDescriptor]] = [:]
    var modifier = NSEvent.ModifierFlags()
    var service: io_service_t = 0
}
