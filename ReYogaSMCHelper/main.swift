//
//  AppDelegate.swift
//  ReYogaSMCHelper
//
//  Created by Zhen on 10/12/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier, identifier.hasSuffix("Helper") else {
            NSApp.terminate(nil)
            return
        }
        let mainBundleID = String(identifier.dropLast("Helper".count))
        let bundlePath = Bundle.main.bundlePath as NSString

        guard NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID).isEmpty else {
            return NSApp.terminate(self)
        }

        let pathComponents = bundlePath.pathComponents
        guard pathComponents.count > 4 else { NSApp.terminate(nil); return }
        let path = NSString.path(withComponents: Array(pathComponents.dropLast(4)))

        let appBundle = Bundle(path: path) ?? .main
        let preferences = UserDefaults(suiteName: mainBundleID)?.stringArray(forKey: "AppleLanguages")
        let language = Bundle.preferredLocalizations(from: appBundle.localizations, forPreferences: preferences).first
        let messages = language.flatMap { appBundle.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? appBundle
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    let alert = NSAlert()
                    alert.messageText = messages.localizedString(forKey: "Could not open ReYogaSMC", value: nil, table: nil)
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: messages.localizedString(forKey: "OK", value: nil, table: nil))
                    alert.runModal()
                }
                NSApp.terminate(nil)
            }
        }
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
