//
//  Item.swift
//  MCP Browser
//
//  Created by Ben Milford on 23/04/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
