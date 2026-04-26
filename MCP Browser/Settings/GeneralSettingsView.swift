//
//  GeneralSettingsView.swift
//  MCP Browser
//
//  General app preferences. Currently houses the history retention
//  window; future cross-cutting toggles land here too.
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(HistoryStore.self) private var history

    @AppStorage(HistoryStore.retentionDaysKey) private var retentionDays: Int = 0
    @AppStorage(BrowserWindow.hibernateAfterMinutesKey) private var hibernateAfterMinutes: Int = 0
    @AppStorage(SearchEngine.storageKey) private var searchEngineRaw: String = SearchEngine.google.rawValue
    @AppStorage(SearchEngine.customTemplateKey) private var customSearchTemplate: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                searchCard
                historyCard
                tabsCard
            }
            .padding(2)
        }
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search")
                .font(.headline)

            Picker("Default search engine", selection: $searchEngineRaw) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.label).tag(engine.rawValue)
                }
            }
            .pickerStyle(.menu)

            if searchEngineRaw == SearchEngine.custom.rawValue {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("https://example.com/search?q={q}",
                              text: $customSearchTemplate)
                        .textFieldStyle(.roundedBorder)
                    Text("Use {q} where the query should be inserted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
    }

    private var tabsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tabs")
                .font(.headline)

            Picker("Hibernate inactive tabs after", selection: $hibernateAfterMinutes) {
                Text("Never").tag(0)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            .pickerStyle(.menu)

            Text("Hibernated tabs release their web content process and reload from a saved session when you switch back. Saves memory at the cost of a brief reload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History")
                .font(.headline)

            Picker("Keep history for", selection: $retentionDays) {
                Text("Forever").tag(0)
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }
            .pickerStyle(.menu)
            .onChange(of: retentionDays) { _, _ in
                history.applyRetention()
            }

            Text("Older entries are pruned on launch and as you browse. Lower windows reduce memory use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
    }
}

#Preview {
    GeneralSettingsView()
        .environment(HistoryStore())
        .padding()
        .frame(width: 520, height: 400)
}
