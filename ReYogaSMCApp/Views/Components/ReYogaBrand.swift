//
//  ReYogaBrand.swift
//  ReYogaSMC
//
//  Created by Zhen on 10/14/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import Foundation

enum ReYogaBrand {
    static func menuImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = rect.width / 18
            let path = NSBezierPath()
            path.lineWidth = 1.8 * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 5*scale, y: 3*scale))
            path.line(to: NSPoint(x: 5*scale, y: 14*scale))
            path.line(to: NSPoint(x: 13*scale, y: 14*scale))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 11*scale, y: 2*scale, width: 3*scale, height: 3*scale)).fill()
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
    static func controlSymbol(_ key: String, value: Int) -> String {
        if key == "SmartFanMode" { return value == 1 ? "leaf.fill" : value == 3 ? "flame.fill" : "speedometer" }
        return ["ConservationMode": "battery.75", "RapidChargeMode": "bolt.fill",
            "AlwaysOnUSBState": "powerplug", "FnlockMode": "fn", "DisplayOverDrive": "display",
            "TouchpadLock": "hand.point.up", "YLogoStatus": "lightbulb", "PortLighting": "powerplug",
            "CPUBoostPower": "cpu", "CPUSustainedPower": "cpu", "CPUPowerReset": "cpu",
            "FanFullSpeed": "wind", "FanControlMode": "wind", "Fan1TargetRPM": "wind", "Fan2TargetRPM": "wind"][key] ?? "gearshape"
    }
    static func eventSymbol(_ name: String) -> String? {
        let symbols = ["AirplaneMode": "airplane", "Antenna": "antenna.radiowaves.left.and.right",
            "Mic": "mic", "MicOff": "mic.slash", "Keyboard": "keyboard", "KeyboardOff": "keyboard",
            "Wifi": "wifi", "WifiOff": "wifi.slash", "BacklightHigh": "light.max", "BacklightLow": "light.min",
            "BacklightOff": "light.min", "CapslockOn": "capslock", "CapslockOff": "capslock",
            "Dock": "rectangle.connected.to.line.below", "Undock": "rectangle",
            "Bluetooth": "wave.3.right", "Camera": "camera", "FunctionKey": "fn", "FunctionKeyOff": "fn",
            "FunctionKeyOn": "fn", "SecondDisplay": "display", "Sleep": "moon"]
        return symbols[name]
    }
}
