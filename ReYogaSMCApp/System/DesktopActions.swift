//
//  DesktopActions.swift
//  ReYogaSMCApp
//
//  Created by Zhen on 12/22/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit
import os.log

func launchApplication(at url: URL, title: String, image: NSString? = nil, display: Bool) {
    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
        DispatchQueue.main.async {
            if let error = error {
                ReYogaDiagnostics.shared.record("hotkey_launch_failed", ["application": url.lastPathComponent, "error": error.localizedDescription])
                showOSDRaw(localizedMessage("Could not open %@: %@", localizedMessage(title), error.localizedDescription))
            } else if display { showOSD(title, image) }
        }
    }
}

func performDesktopAction(_ action: EventAction, title: String? = nil, image: NSString? = nil) {
    switch action {
    case .desktop: CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, nil)
    case .expose: CoreDockSendNotification("com.apple.expose.front.awake" as CFString, nil)
    case .mission: CoreDockSendNotification("com.apple.expose.awake" as CFString, nil)
    case .launchpad: CoreDockSendNotification("com.apple.launchpad.toggle" as CFString, nil)
    case .displaysettings, .mirror:
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") { NSWorkspace.shared.open(url) }
    default: return
    }
    if let title = title { showOSD(title, image) }
}
