//
//  DriverNotifications.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 12/22/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import Foundation
import IOKit
import os.log

func registerNotification(_ context: DriverEventContext) -> Bool {
    var portContext = CFMachPortContext(version: 0, info: Unmanaged.passUnretained(context).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
    guard let port = CFMachPortCreate(kCFAllocatorDefault, notificationCallback, &portContext, nil),
          let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
    let ret = IOConnectSetNotificationPort(context.connect, 0, CFMachPortGetPort(port), 0)
    guard ret == kIOReturnSuccess else {
        CFMachPortInvalidate(port)
        ReYogaDiagnostics.shared.record("notification_registration_failed", ["status": ret])
        return false
    }
    context.notificationPort = port
    context.notificationSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    return true
}

func notificationCallback(
    _ port: CFMachPort?,
    _ msg: UnsafeMutableRawPointer?,
    _ size: CFIndex,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info = info, let msg = msg, size >= MemoryLayout<SMCNotificationMessage>.size else {
        os_log("Invalid config", type: .error)
        return
    }

    let context = Unmanaged<DriverEventContext>.fromOpaque(info).takeUnretainedValue()
    let notification = msg.load(as: SMCNotificationMessage.self)
    ReYogaDiagnostics.shared.record("ec_notification", ["event": notification.event, "data": notification.data])

    dispatchDriverEvent(notification, context: context)
}
