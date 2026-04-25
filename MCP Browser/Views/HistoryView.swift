//
//  HistoryView.swift
//  MCP Browser
//

import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(BrowserTab.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !store.entries.isEmpty {
                    Button(role: .destructive) {
                        store.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history and page text", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            Divider()
            if store.entries.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No matches").font(.body.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.key) { group in
                        Section(header: Text(group.key).font(.caption).foregroundStyle(.secondary)) {
                            ForEach(group.value) { entry in
                                row(for: entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 560)
    }

    private var filtered: [HistoryEntry] {
        store.search(query)
    }

    /// Groups entries by day header (Today / Yesterday / date). Reasonably
    /// cheap given the list is always rendered in full by SwiftUI anyway.
    private var groups: [(key: String, value: [HistoryEntry])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.doesRelativeDateFormatting = false

        var result: [(key: String, value: [HistoryEntry])] = []
        var current: (key: String, value: [HistoryEntry])?

        for entry in filtered {
            let start = cal.startOfDay(for: entry.visitedAt)
            let daysAgo = cal.dateComponents([.day], from: start, to: today).day ?? 0
            let label: String
            switch daysAgo {
            case 0: label = "Today"
            case 1: label = "Yesterday"
            default: label = df.string(from: entry.visitedAt)
            }

            if var c = current, c.key == label {
                c.value.append(entry)
                current = c
            } else {
                if let c = current { result.append(c) }
                current = (key: label, value: [entry])
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No history")
                .font(.body.weight(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(for entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
                Text(entry.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(entry.visitedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                store.remove(id: entry.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            browser.navigate(to: entry.url)
            dismiss()
        }
    }
}
