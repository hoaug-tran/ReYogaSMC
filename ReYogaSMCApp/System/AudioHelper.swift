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

private func defaultAudioDevice(for prop: AudioObjectPropertyAddress) -> AudioDeviceID? {
    guard let device = try? AudioProperty<AudioDeviceID>(device: nil, prop: prop).get().get(),
          device != AudioDeviceID(kAudioObjectUnknown) else {
        return nil
    }
    return device
}

private func outputMuteAddress(for device: AudioDeviceID) -> AudioObjectPropertyAddress? {
    for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        if AudioObjectHasProperty(device, &addr) {
            return addr
        }
    }
    return nil
}

private func currentOutputMute() -> Bool? {
    if let outputDevice = defaultAudioDevice(for: defaultOutputDeviceProp),
       let addr = outputMuteAddress(for: outputDevice),
       let value = try? AudioProperty<UInt32>(device: outputDevice, prop: addr).get().get() {
        return value != 0
    }
    return scriptHelper(getAudioMutedAS, "Mute")?.booleanValue
}

private func currentInputMute() -> Bool? {
    if let inputDevice = defaultAudioDevice(for: defaultInputDeviceProp),
       let value = try? AudioProperty<UInt32>(device: inputDevice, prop: muteInputVolumeProp).get().get() {
        return value != 0
    }
    return scriptHelper(getMicVolumeAS, "MicMute").map { $0.int32Value == 0 }
}

final class CoreAudioMuteObserver {
    private let queue = DispatchQueue.main
    private var isStarted = false
    private var systemListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var observedDevice: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var observedAddress: AudioObjectPropertyAddress?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        stop()
        isStarted = true
        self.onChange = onChange

        var addr = defaultOutputDeviceProp
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, self.isStarted else { return }
            self.refreshDevice()
            self.onChange?()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        if status == noErr {
            systemListenerBlock = block
        } else {
            os_log("Failed to observe default output audio device (0x%08x)", type: .error, status)
        }
        refreshDevice()
    }

    func refreshDevice() {
        guard isStarted else { return }
        detachDeviceListener()
        guard let device = defaultAudioDevice(for: defaultOutputDeviceProp),
              var addr = outputMuteAddress(for: device) else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, self.isStarted else { return }
            self.onChange?()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &addr, queue, block)
        if status == noErr {
            observedDevice = device
            observedAddress = addr
            deviceListenerBlock = block
        } else {
            os_log("Failed to observe output mute property (0x%08x)", type: .error, status)
        }
    }

    func stop() {
        isStarted = false
        onChange = nil
        detachDeviceListener()
        if let block = systemListenerBlock {
            var addr = defaultOutputDeviceProp
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            systemListenerBlock = nil
        }
    }

    private func detachDeviceListener() {
        guard observedDevice != AudioDeviceID(kAudioObjectUnknown),
              var addr = observedAddress,
              let block = deviceListenerBlock else {
            observedDevice = AudioDeviceID(kAudioObjectUnknown)
            observedAddress = nil
            deviceListenerBlock = nil
            return
        }
        _ = AudioObjectRemovePropertyListenerBlock(observedDevice, &addr, queue, block)
        observedDevice = AudioDeviceID(kAudioObjectUnknown)
        observedAddress = nil
        deviceListenerBlock = nil
    }

    deinit {
        stop()
    }
}

class AudioHelper {
    let inputDevice: AudioDeviceID
    let inputVolume: AudioProperty<Float>
    let inputMute: AudioProperty<UInt32>

    static func forCurrentDevices() -> AudioHelper? { AudioHelper() }

    init?() {
        guard let inputDevice = defaultAudioDevice(for: defaultInputDeviceProp) else {
            os_log("Failed to initialize AudioHelper!", type: .error)
            return nil
        }
        self.inputDevice = inputDevice
        self.inputVolume = AudioProperty<Float>(device: inputDevice, prop: primaryInputVolumeProp)
        self.inputMute = AudioProperty<UInt32>(device: inputDevice, prop: muteInputVolumeProp)
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
}

func micMuteLEDHelper(_ service: io_service_t) {
    guard service != 0, let mute = currentInputMute() else {
        os_log("Failed to update Mic Mute LED", type: .error)
        return
    }
    guard sendNumber("MicMuteLED", mute ? 2 : 0, service) else {
        os_log("Failed to update Mic Mute LED", type: .error)
        return
    }
    os_log("Mic Mute LED updated", type: .info)
}

private var lastMuteLEDStatus: Bool?

func resetMuteLEDStatusCache() {
    lastMuteLEDStatus = nil
}

func muteLEDHelper(_ service: io_service_t, _ wake: Bool = true) {
    guard service != 0 else { return }
    guard let mute = currentOutputMute() else {
        os_log("Failed to update Mute LED", type: .error)
        return
    }
    if !wake, let last = lastMuteLEDStatus, mute == last { return }
    guard sendBoolean("MuteLED", mute, service) else {
        os_log("Failed to update Mute LED", type: .error)
        return
    }
    lastMuteLEDStatus = mute
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
