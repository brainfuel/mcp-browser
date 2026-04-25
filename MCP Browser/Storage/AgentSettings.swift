//
//  AgentSettings.swift
//  MCP Browser
//
//  User-controllable behaviors for the MCP agent integration:
//  cursor overlay, confirm-before-submit on sensitive hosts, and the
//  sensitive-domain list itself. Persisted to disk so toggles survive
//  restarts.
//

import Foundation
import Observation

@MainActor
@Observable
final class AgentSettings {
    /// When true, DOM-targeting tool calls (click/fill/scroll/...) flash
    /// a blue overlay over the element they hit so the user can see
    /// what the agent just did.
    var cursorEnabled: Bool = true {
        didSet { persist() }
    }

    /// When true, pages on `sensitiveDomains` must confirm via native
    /// sheet before submitting any form.
    var confirmOnSensitive: Bool = true {
        didSet { persist() }
    }

    /// Lowercased substrings matched against `location.hostname`. A
    /// host is sensitive if it equals, ends with `.<entry>`, or contains
    /// the entry — so "bank" matches `mybank.com`, `paypal.com` matches
    /// `www.paypal.com`.
    var sensitiveDomains: [String] = ["bank", "paypal.com", "amazon.com", "stripe.com"] {
        didSet { persist() }
    }

    /// Picture-in-picture thumbnail floating above other windows. The
    /// PiP controller snapshots the active tab after every MCP tool
    /// call and updates the panel.
    var pipEnabled: Bool = false {
        didSet {
            persist()
            onPipToggled?(pipEnabled)
        }
    }

    /// Called after `pipEnabled` flips. Wired by MCPCoordinator to the
    /// PipController so the panel opens/closes immediately.
    var onPipToggled: ((Bool) -> Void)?

    private let fileURL = PersistentStore.url(for: "agent-settings.json")

    private struct Payload: Codable {
        var cursorEnabled: Bool
        var confirmOnSensitive: Bool
        var sensitiveDomains: [String]
        var pipEnabled: Bool?
    }

    init() {
        if let p: Payload = PersistentStore.load(Payload.self, from: fileURL) {
            cursorEnabled = p.cursorEnabled
            confirmOnSensitive = p.confirmOnSensitive
            sensitiveDomains = p.sensitiveDomains
            pipEnabled = p.pipEnabled ?? false
        }
    }

    private func persist() {
        let p = Payload(
            cursorEnabled: cursorEnabled,
            confirmOnSensitive: confirmOnSensitive,
            sensitiveDomains: sensitiveDomains,
            pipEnabled: pipEnabled
        )
        PersistentStore.save(p, to: fileURL)
    }
}
