//
//  Item.swift
//  PulseLoop
//
//  Created by Saksham Bhutani on 5/31/26.
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
