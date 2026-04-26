//
//  MCP_BrowserApp.swift
//  MCP Browser
//
//  App entry point. Each window owns its own BrowserWindow. The
//  MCPCoordinator routes tool calls to the focused window's active
//  tab and holds the shared AgentSettings / ActionLog / Recorder.
//

import SwiftUI

@main
struct MCP_BrowserApp: App {
    @State private var agentSettings: AgentSettings
    @State private var actionLog: ActionLog
    @State private var recorder: Recorder
    @State private var coordinator: MCPCoordinator
    @State private var bookmarks: BookmarkStore
    @State private var history = HistoryStore()
    @State private var favicons = FaviconService()
    @State private var downloads = DownloadStore()

    init() {
        let settings = AgentSettings()
        let log = ActionLog()
        let rec = Recorder()
        let presenter = DefaultBrowserPresenter()
        let bm = BookmarkStore()
        _agentSettings = State(initialValue: settings)
        _actionLog = State(initialValue: log)
        _recorder = State(initialValue: rec)
        _bookmarks = State(initialValue: bm)
        _coordinator = State(initialValue: MCPCoordinator(
            agentSettings: settings,
            actionLog: log,
            recorder: rec,
            presenter: presenter,
            bookmarks: bm
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .environment(bookmarks)
                .environment(history)
                .environment(agentSettings)
                .environment(actionLog)
                .environment(recorder)
                .environment(favicons)
                .environment(downloads)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }
    }
}
