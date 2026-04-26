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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                historyCard
            }
            .padding(2)
        }
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
