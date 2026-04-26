//
//  SettingsView.swift
//  MCP Browser
//
//  Tabbed settings sheet: connection info, bookmarks import, agent
//  behavior toggles, and the MCP action log.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    static let endpoint = MCPCoordinator.endpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ConnectionSettingsView(endpoint: Self.endpoint)
                    .tabItem { Label("Connection", systemImage: "network") }
                BookmarksSettingsView()
                    .tabItem { Label("Bookmarks", systemImage: "book") }
                AgentSettingsSectionView()
                    .tabItem { Label("Agent", systemImage: "cursorarrow.rays") }
                PrivacySettingsView()
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
                RecorderSettingsView(endpoint: Self.endpoint)
                    .tabItem { Label("Recorder", systemImage: "record.circle") }
                ActionLogSettingsView(endpoint: Self.endpoint)
                    .tabItem { Label("Action Log", systemImage: "list.bullet.rectangle") }
            }
            .padding(14)
        }
        .frame(width: 640, height: 640)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#Preview {
    let settings = AgentSettings()
    let log = ActionLog()
    let recorder = Recorder()

    SettingsView()
        .environment(MCPCoordinator(
            agentSettings: settings,
            actionLog: log,
            recorder: recorder,
            presenter: DefaultBrowserPresenter()
        ))
        .environment(settings)
        .environment(log)
        .environment(BookmarkStore())
        .environment(HistoryStore())
        .environment(recorder)
}
