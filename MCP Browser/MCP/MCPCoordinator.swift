//
//  MCPCoordinator.swift
//  MCP Browser
//
//  Owns the MCP server, the floating PiP panel, and the shared
//  agent-behavior toggles. Conforms to `MCPHost` so the tool registry
//  has a single dependency to talk to.
//

import Foundation

@MainActor
@Observable
final class MCPCoordinator: MCPHost {

    // MARK: - Public surface

    private(set) var server: MCPServer?

    /// Focused window's tabs. Tool calls re-resolve through this on
    /// every invocation so they follow window focus.
    private(set) var activeTabs: BrowserWindow?

    var activeBrowser: BrowserTab? { activeTabs?.active }

    let agentSettings: AgentSettings
    let actionLog: ActionLog
    let pip: PipController
    let recorder: Recorder
    let presenter: BrowserPresenter

    // MARK: - State

    private var registered: [Weak<BrowserWindow>] = []

    private struct Weak<T: AnyObject> { weak var value: T? }

    // MARK: - Init

    init(agentSettings: AgentSettings,
         actionLog: ActionLog,
         recorder: Recorder,
         presenter: BrowserPresenter) {
        self.agentSettings = agentSettings
        self.actionLog = actionLog
        self.recorder = recorder
        self.presenter = presenter
        self.pip = PipController(settings: agentSettings)

        agentSettings.onPipToggled = { [weak pip = self.pip] _ in
            pip?.refresh()
        }
        recorder.onStateChange = { [weak self] _ in
            self?.applyRecordingToAllTabs()
        }
    }

    // MARK: - Window lifecycle

    /// Register a window's tabs container. First registration boots
    /// the MCP server. Hands per-tab dependencies down so tabs don't
    /// need to know about the coordinator.
    func register(tabs: BrowserWindow, port: UInt16) {
        tabs.agentSettings = agentSettings
        tabs.recorder = recorder
        tabs.presenter = presenter
        registered.append(Weak(value: tabs))
        if activeTabs == nil { activeTabs = tabs }
        bootServerIfNeeded(port: port)
    }

    func setActive(_ tabs: BrowserWindow) {
        activeTabs = tabs
    }

    func unregister(_ tabs: BrowserWindow) {
        registered.removeAll { $0.value === tabs || $0.value == nil }
        if activeTabs === tabs {
            activeTabs = registered.compactMap(\.value).first
        }
    }

    // MARK: - Internals

    private func bootServerIfNeeded(port: UInt16) {
        guard server == nil else { return }
        do {
            let s = try MCPServer(port: port, host: { [weak self] in self })
            try s.start()
            server = s
        } catch {
            NSLog("MCP server failed to start: \(error)")
        }
    }

    private func applyRecordingToAllTabs() {
        for entry in registered {
            entry.value?.tabs.forEach { $0.applyAgentStateExternally() }
        }
    }
}
