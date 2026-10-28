import AppKit
import Foundation
import os.log

let sleepAS = "tell application \"System Events\" to sleep"
let searchAS = "tell application \"System Events\" to keystroke space using {command down, option down}"
let spotlightAS = "tell application \"System Events\" to keystroke space using command down"

let getAudioMutedAS = "output muted of (get volume settings)"
let getMicVolumeAS = "input volume of (get volume settings)"
let setMicVolumeAS = "set volume input volume %d"

func scriptHelper(_ source: String, _ name: String, _ image: NSString? = nil) -> NSAppleEventDescriptorriptor? {
    if let scpt = NSAppleScript(source: source) {
        var error: NSDictionary?
        let ret = scpt.executeAndReturnError(&error)
        if error == nil {
            if let img = image {
                showOSD(name, img)
            }
            return ret
        }
    }
    os_log("%s: failed to execute script", type: .error, name)
    return nil
}
