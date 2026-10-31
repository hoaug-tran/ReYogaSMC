//
//  ColorPanelPlacement.swift
//  ReYogaSMC
//
//  Created by Zhen on 10/14/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import AppKit

struct ColorPanelPlacement {
    static func origin(panelSize: NSSize, anchor: NSRect, owner: NSRect, visible: NSRect) -> NSPoint {
        let gap: CGFloat = 12
        let preferredX = owner.maxX + gap + panelSize.width <= visible.maxX
            ? owner.maxX + gap : owner.minX - gap - panelSize.width
        return NSPoint(x: min(max(preferredX, visible.minX), max(visible.minX, visible.maxX - panelSize.width)),
                       y: min(max(anchor.maxY - panelSize.height, visible.minY), max(visible.minY, visible.maxY - panelSize.height)))
    }
}
