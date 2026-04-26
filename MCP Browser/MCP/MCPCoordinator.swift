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
    static let defaultPort: UInt16 = 8833
    static let endpoint = "http://127.0.0.1:\(defaultPort)/mcp"

    enum ServerState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    // MARK: - Public surface

    private(set) var server: MCPServer?
    private(set) var serverState: ServerState = .stopped

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

        bootServerIfNeeded()
    }

    // MARK: - Window lifecycle

    /// Register a window's tabs container so tool calls can follow the
    /// focused browser window. The server boots eagerly at app launch,
    /// but we still re-check here as a defensive fallback.
    func register(tabs: BrowserWindow) {
        tabs.agentSettings = agentSettings
        tabs.recorder = recorder
        tabs.presenter = presenter
        registered.append(Weak(value: tabs))
        if activeTabs == nil { activeTabs = tabs }
        bootServerIfNeeded()
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

    private func bootServerIfNeeded() {
        guard server == nil else { return }
        serverState = .starting
        do {
            let s = try MCPServer(
                port: Self.defaultPort,
                host: { [weak self] in self },
                onStateChange: { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.handleServerStateChange(state)
                    }
                }
            )
            try s.start()
            server = s
        } catch {
            serverState = .failed(error.localizedDescription)
            NSLog("MCP server failed to start: \(error)")
        }
    }

    private func handleServerStateChange(_ state: MCPServer.LifecycleState) {
        switch state {
        case .starting:
            serverState = .starting
        case .ready:
            serverState = .running
        case .failed(let message):
            serverState = .failed(message)
        case .stopped:
            serverState = .stopped
        }
    }

    private func applyRecordingToAllTabs() {
        for entry in registered {
            entry.value?.tabs.forEach { $0.applyAgentStateExternally() }
        }
    }
}
