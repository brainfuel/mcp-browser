//
//  ZoomStore.swift
//  MCP Browser
//
//  Per-host page zoom persisted to UserDefaults. Hosts at the default
//  100% are stored as nothing (key removed) so the defaults database
//  stays small.
//

import Foundation

enum ZoomStore {
    private static let prefix = "zoom."
    private static let defaultZoom: Double = 1.0
    static let minZoom: Double = 0.25
    static let maxZoom: Double = 5.0
    /// Multiplicative step for ⌘+ / ⌘-. ~10% feels close to Safari.
    static let step: Double = 1.1

    static func zoom(for host: String?) -> Double {
        guard let host, !host.isEmpty else { return defaultZoom }
        let stored = UserDefaults.standard.double(forKey: prefix + host)
        return stored == 0 ? defaultZoom : stored
    }

    static func set(_ zoom: Double, for host: String?) {
        guard let host, !host.isEmpty else { return }
        let clamped = clamp(zoom)
        if abs(clamped - defaultZoom) < 0.001 {
            UserDefaults.standard.removeObject(forKey: prefix + host)
        } else {
            UserDefaults.standard.set(clamped, forKey: prefix + host)
        }
    }

    static func clamp(_ zoom: Double) -> Double {
        max(minZoom, min(maxZoom, zoom))
    }
}
