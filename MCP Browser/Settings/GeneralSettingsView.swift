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
    @AppStorage(BrowserTab.showAccessibilityIndicatorKey) private var showA11yIndicator: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                searchCard
                historyCard
                tabsCard
                accessibilityCard
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

    private var accessibilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accessibility")
                .font(.headline)

            Toggle(isOn: $showA11yIndicator) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Warn when a page is hard for agents to drive")
                    Text("Shows a slim banner under the address bar when the current page has weak (amber) or poor (red) accessibility markup. Pages with strong markup show no banner. AI agents — and screen readers — work much better on pages with proper roles and labels, so this is a quick signal of how reliably an agent will be able to drive a site. Hover the banner for the underlying score.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
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
