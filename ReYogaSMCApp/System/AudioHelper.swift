//
//  AudioHelper.swift
//  ReYogaSMC
//
//  Created by Zhen on 12/9/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import os.log

// from https://gist.github.com/mblsha/f6db715ca6245b36eb1fa6d8af23cf4b

private let defaultInputDeviceProp = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

private let defaultOutputDeviceProp = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

private let primaryInputVolumeProp = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain)

private let muteInputVolumeProp = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyMute,
    mScope: kAudioDevicePropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain)

private let muteOutputVolumeProp = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyMute,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain)

enum AudioPropertyError: Error {
    case noProperty
    case propertyNotSettable
    case getPropertyData(OSStatus)
    case setPropertyData(OSStatus)
    case emptyResult
}

protocol AudioScalar {
    static var zero: Self { get }
}
extension Float: AudioScalar {}
extension UInt32: AudioScalar {}

struct AudioProperty<T: AudioScalar> {
    let device: AudioDeviceID
    let prop: AudioObjectPropertyAddress

    init(device: AudioDeviceID?, prop: AudioObjectPropertyAddress) {
        self.device = device ?? UInt32(kAudioObjectSystemObject)
        self.prop = prop
    }

    func get() -> Result<T, AudioPropertyError> {
        var addr = prop
        if !AudioObjectHasProperty(device, &addr) {
            return .failure(.noProperty)
        }

        var size = UInt32(MemoryLayout<T>.size)
        var result = T.zero
        let error = withUnsafeMutableBytes(of: &result) { bytes in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, bytes.baseAddress!)
        }

        if error != noErr {
            return .failure(.getPropertyData(error))
        }

        guard size == MemoryLayout<T>.size else { return .failure(.emptyResult) }
        return .success(result)
    }

    func set(_ newValue: T) -> Result<T, AudioPropertyError> {
        var addr = prop
        if !AudioObjectHasProperty(device, &addr) {
            return .failure(.noProperty)
        }

        var settable: DarwinBoolean = false
        var error = AudioObjectIsPropertySettable(device, &addr, &settable)
        if error != noErr || !settable.boolValue {
            return .failure(.propertyNotSettable)
        }

        let size = UInt32(MemoryLayout<T>.size)
        var value = newValue
        error = withUnsafeBytes(of: &value) { bytes in
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, bytes.baseAddress!)
        }
        if error != noErr {
            return .failure(.setPropertyData(error))
        }

        return .success(value)
    }
}

class AudioHelper {
    let inputDevice: AudioDeviceID
    let outputDevice: AudioDeviceID

    let inputVolume: AudioProperty<Float>

    let inputMute: AudioProperty<UInt32>
    let outputMute: AudioProperty<UInt32>

    private static var muteLEDStatus = false

    static func forCurrentDevices() -> AudioHelper? { AudioHelper() }

    init?() {
        do {
            try inputDevice = AudioProperty<AudioDeviceID>(
                device: nil,
                prop: defaultInputDeviceProp
            ).get().get()
            try outputDevice = AudioProperty<AudioDeviceID>(
                device: nil,
                prop: defaultOutputDeviceProp
            ).get().get()
        } catch {
            os_log("Failed to initialize AudioHelper!", type: .error)
            return nil
        }

        self.inputVolume = AudioProperty<Float>(device: inputDevice, prop: primaryInputVolumeProp)

        self.inputMute = AudioProperty<UInt32>(device: inputDevice, prop: muteInputVolumeProp)
        self.outputMute = AudioProperty<UInt32>(device: outputDevice, prop: muteOutputVolumeProp)
    }

    func micMuteHelper(_ service: io_service_t, _ name: String) {
        do {
            if try inputMute.get().get() != 0 {
                if try inputVolume.get().get() == 0 {
                    guard try inputVolume.set(0.50).get() == 0.50 else {
                        throw AudioPropertyError.emptyResult
                    }
                }
                guard try inputMute.set(0).get() == 0,
                      try inputMute.get().get() == 0 else {
                    throw AudioPropertyError.noProperty
                }
                if getProperties(service)?["MicMuteLED"] != nil { _ = sendNumber("MicMuteLED", 0, service) }
                showOSDRes(name, "Unmute", .kMic)
            } else {
                guard try inputMute.set(1).get() == 1,
                      try inputMute.get().get() == 1 else {
                    throw AudioPropertyError.noProperty
                }
                if getProperties(service)?["MicMuteLED"] != nil { _ = sendNumber("MicMuteLED", 2, service) }
                showOSDRes(name, "Mute", .kMicOff)
            }
        } catch {
            showOSDRes("Mic", "Toggle failed", .kMic)
            os_log("Mic toggle failed!", type: .error)
        }
    }

    func micMuteLEDHelper(_ service: io_service_t) {
        do {
            let mute = try inputMute.get().get() != 0
            guard sendNumber("MicMuteLED", mute ? 2 : 0, service) else {
                throw AudioPropertyError.noProperty
            }
            os_log("Mic Mute LED updated", type: .info)
        } catch {
            os_log("Failed to update Mic Mute LED", type: .error)
        }
    }

    func muteLEDHelper(_ service: io_service_t, _ wake: Bool) {
        do {
            let mute = try outputMute.get().get() != 0
            if !wake, mute == Self.muteLEDStatus { return }
            guard sendBoolean("MuteLED", mute, service) else {
                throw AudioPropertyError.noProperty
            }
            Self.muteLEDStatus = mute
            os_log("Mute LED updated", type: .info)
        } catch {
            os_log("Failed to update Mute LED", type: .error)
        }
    }
}

func micMuteLEDHelper(_ service: io_service_t) {
    if let audio = AudioHelper.forCurrentDevices() {
        audio.micMuteLEDHelper(service)
        return
    }

    guard let current = scriptHelper(getMicVolumeAS, "MicMute") else { return }
    _ = sendNumber("MicMuteLED", current.int32Value != 0 ? 0 : 2, service)
}

private var muteLEDStatus = false

func muteLEDHelper(_ service: io_service_t, _ wake: Bool = true) {
    if let audio = AudioHelper.forCurrentDevices() {
        audio.muteLEDHelper(service, wake)
        return
    }

    guard let current = scriptHelper(getAudioMutedAS, "Mute") else { return }
    if !wake, current.booleanValue == muteLEDStatus { return }
    guard sendBoolean("MuteLED", current.booleanValue, service) else {
        os_log("Failed to update Mute LED", type: .error)
        return
    }
    muteLEDStatus = current.booleanValue
    os_log("Mute LED updated", type: .info)
}

private var muteVolume: Int32 = 50

func micMuteHelper(_ service: io_service_t, _ name: String) {
    if let audio = AudioHelper.forCurrentDevices() {
        audio.micMuteHelper(service, name)
        return
    }

    guard let current = scriptHelper(getMicVolumeAS, "MicMute") else { return }
    if current.int32Value != 0 {
        if scriptHelper(String(format: setMicVolumeAS, 0), "MicMute") != nil {
            muteVolume = current.int32Value
            _ = sendNumber("MicMuteLED", 2, service)
            showOSDRes(name, "Mute", .kMicOff)
        }
    } else {
        if scriptHelper(String(format: setMicVolumeAS, muteVolume), "MicMute") != nil {
            _ = sendNumber("MicMuteLED", 0, service)
            showOSDRes(name, "Unmute", .kMic)
        }
    }
}
