//
//  PrivacySettingsView.swift
//  MCP Browser
//
//  Privacy tab in the Settings sheet. Lets the user wipe browsing
//  data: history, cookies, cache, and broader site storage. Each
//  bucket maps to one or more `WKWebsiteDataStore` data types so the
//  user can pick what to clear without nuking everything.
//

import SwiftUI
import WebKit

struct PrivacySettingsView: View {
    @Environment(HistoryStore.self) private var history

    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearSiteData = false

    @State private var working = false
    @State private var lastMessage: String?
    @State private var showingConfirm = false

    @AppStorage(BrowserTab.cookieConsentPolicyKey)
    private var cookieConsentRaw: String = CookieConsentPolicy.declineOptional.rawValue

    private var cookieConsentPolicy: Binding<CookieConsentPolicy> {
        Binding(
            get: { CookieConsentPolicy(rawValue: cookieConsentRaw) ?? .declineOptional },
            set: { cookieConsentRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                cookieConsentCard
                clearCard
                noteCard
            }
            .padding(2)
        }
    }

    private var cookieConsentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cookie Banners")
                .font(.headline)

            Picker("Default action", selection: cookieConsentPolicy) {
                ForEach(CookieConsentPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.menu)

            Text(cookieConsentPolicy.wrappedValue.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Applies on the next navigation. Already-loaded pages aren't retroactively cleaned.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
    }

    private var clearCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clear Browsing Data")
                .font(.headline)
            Toggle("Browsing history", isOn: $clearHistory)
            Toggle("Cookies", isOn: $clearCookies)
            Toggle("Cache (images, scripts)", isOn: $clearCache)
            Toggle("Other site data (local storage, IndexedDB, service workers)",
                   isOn: $clearSiteData)

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    showingConfirm = true
                } label: {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Clear Now")
                    }
                }
                .disabled(working || !anySelected)

                if let lastMessage {
                    Text(lastMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
        .confirmationDialog(
            "Clear the selected data? This can't be undone.",
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note")
                .font(.headline)
            Text("Already-open tabs keep their current pages. New navigations will run against the cleared store.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
    }

    private var anySelected: Bool {
        clearHistory || clearCookies || clearCache || clearSiteData
    }

    private func clear() {
        working = true
        lastMessage = nil

        if clearHistory {
            history.clear()
        }

        var types = Set<String>()
        if clearCookies {
            types.insert(WKWebsiteDataTypeCookies)
        }
        if clearCache {
            types.formUnion([
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache,
            ])
        }
        if clearSiteData {
            types.formUnion([
                WKWebsiteDataTypeLocalStorage,
                WKWebsiteDataTypeSessionStorage,
                WKWebsiteDataTypeIndexedDBDatabases,
                WKWebsiteDataTypeWebSQLDatabases,
                WKWebsiteDataTypeServiceWorkerRegistrations,
            ])
        }

        let history = clearHistory
        let store = WKWebsiteDataStore.default()
        if types.isEmpty {
            finish(historyCleared: history, dataTypeCount: 0)
            return
        }
        // `removeData(...)` since the epoch wipes everything of those
        // types. Completion fires on the main queue.
        store.removeData(ofTypes: types, modifiedSince: .distantPast) {
            finish(historyCleared: history, dataTypeCount: types.count)
        }
    }

    private func finish(historyCleared: Bool, dataTypeCount: Int) {
        working = false
        var parts: [String] = []
        if historyCleared { parts.append("history") }
        if dataTypeCount > 0 { parts.append("\(dataTypeCount) website data type\(dataTypeCount == 1 ? "" : "s")") }
        if parts.isEmpty {
            lastMessage = "Nothing selected."
        } else {
            lastMessage = "Cleared " + parts.joined(separator: " and ") + "."
        }
    }
}

#Preview {
    PrivacySettingsView()
        .environment(HistoryStore())
        .padding()
        .frame(width: 520, height: 400)
}
