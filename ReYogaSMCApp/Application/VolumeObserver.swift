//
//  VolumeObserver.swift
//  ReYogaSMC
//
//  Created by Zhen on 12/9/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation

class VolumeObserver: NSApplication {
    static let volumeChanged = Notification.Name("ReYogaSMC.volumeChanged")

    //from https://stackoverflow.com/a/32769093/6884062
    override func sendEvent(_ event: NSEvent) {
        if event.type == .systemDefined && event.subtype.rawValue == 8 {
            let keyCode = Int32((event.data1 & 0xFFFF0000) >> 16)
            postVolumeChange(for: keyCode)
        }

        super.sendEvent(event)
    }

    private func postVolumeChange(for key: Int32) {
        switch key {
        case NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_MUTE:
            NotificationCenter.default.post(name: VolumeObserver.volumeChanged, object: self)
        default:
            break
        }
    }
}
