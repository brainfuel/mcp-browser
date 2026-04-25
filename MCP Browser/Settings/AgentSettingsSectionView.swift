//
//  AgentSettingsSectionView.swift
//  MCP Browser
//
//  "Agent" tab in Settings: toggles for the cursor overlay and the
//  submit-confirm guard, plus the editable list of sensitive domains.
//

import SwiftUI

struct AgentSettingsSectionView: View {
    @Environment(AgentSettings.self) private var settings
    @State private var newDomain: String = ""

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                togglesCard(settings: $settings)
                domainsCard
            }
            .padding(8)
        }
    }

    private func togglesCard(settings: Bindable<AgentSettings>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("BEHAVIOR")

            Toggle(isOn: settings.cursorEnabled.animation()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent cursor overlay")
                    Text("Flash a blue highlight on elements the agent clicks, fills, or scrolls to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: settings.confirmOnSensitive.animation()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm form submits on sensitive domains")
                    Text("Require a native confirmation before any form submit on the domains below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: settings.pipEnabled.animation()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Picture-in-picture agent view")
                    Text("Floating always-on-top thumbnail that updates after every MCP tool call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var domainsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("SENSITIVE DOMAINS")
            Text("A host is sensitive if it equals, ends with `.entry`, or contains the entry string (case-insensitive).")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("add a domain (e.g. bank, paypal.com)", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .buttonStyle(.bordered)
                    .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if settings.sensitiveDomains.isEmpty {
                Text("No domains configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(settings.sensitiveDomains, id: \.self) { domain in
                        HStack {
                            Text(domain).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                remove(domain)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private func addDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !settings.sensitiveDomains.contains(trimmed) else { return }
        settings.sensitiveDomains.append(trimmed)
        newDomain = ""
    }

    private func remove(_ domain: String) {
        settings.sensitiveDomains.removeAll { $0 == domain }
    }
}
