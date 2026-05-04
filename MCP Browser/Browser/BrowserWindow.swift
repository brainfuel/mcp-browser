//
//  BrowserWindow.swift
//  MCP Browser
//
//  Per-window container that owns an array of BrowserTabs and tracks
//  which one is active. Acts as the `BrowserTabDelegate` for every
//  tab it owns, so each tab's hooks (new-tab routing, agent-state push,
//  recorder forwarding, history recording) flow through one place.
//

import Foundation
import Observation
import WebKit
import SwiftUI

@MainActor
@Observable
final class BrowserWindow {

    // MARK: - State

    /// Tabs in display order. Always non-empty after init.
    private(set) var tabs: [BrowserTab] = []

    /// The tab currently visible and targeted by MCP tools.
    var activeID: UUID? {
        didSet { handleActiveChange(from: oldValue, to: activeID) }
    }

    /// UserDefaults key for the hibernate-after window (in minutes).
    /// Absent / non-positive value disables hibernation.
    static let hibernateAfterMinutesKey = "tabHibernateAfterMinutes"

    @ObservationIgnored
    private var sweepTimer: Timer?

    /// LIFO of recently-closed tabs' URLs. ⌘⇧T pops one and opens a
    /// fresh tab pointed at the same address. Capped to keep the stack
    /// from growing without bound.
    private var closedURLStack: [String] = []
    private let closedStackLimit = 32

    var active: BrowserTab? {
        tabs.first(where: { $0.id == activeID }) ?? tabs.first
    }

    // MARK: - Owner-supplied dependencies

    /// History store used to record visits + page-text snippets. The
    /// owner sets this once at register time.
    weak var historyRecorder: HistoryStore?

    /// Shared agent settings. Read on every per-tab nav commit.
    weak var agentSettings: AgentSettings? {
        didSet { applyAgentStateToAllTabs() }
    }

    /// Session recorder. Tabs forward DOM events here when active.
    weak var recorder: Recorder?

    /// Native dialog presenter handed down to every tab. Without one,
    /// tabs can't show submit confirms or file pickers.
    weak var presenter: BrowserPresenter?

    /// Shared downloads store. Threaded into every tab so user-initiated
    /// downloads from any tab appear in the same window-level list.
    weak var downloadStore: DownloadStore? {
        didSet {
            for tab in tabs { tab.downloadStore = downloadStore }
        }
    }

    // MARK: - Init

    init() {
        // Windows always render with at least one tab. Seeding here
        // (rather than in onAppear) means BrowserTab is available on
        // the first SwiftUI pass.
        let seed = BrowserTab()
        tabs = [seed]
        activeID = seed.id
        wire(seed)
        startSweepTimer()
    }

    deinit {
        sweepTimer?.invalidate()
    }

    private func startSweepTimer() {
        // Re-check inactivity every minute. The closure does the cheap
        // path itself; if the user has hibernation off, it returns
        // immediately.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runHibernationSweep() }
        }
    }

    private func runHibernationSweep() {
        let mins = UserDefaults.standard.integer(forKey: Self.hibernateAfterMinutesKey)
        guard mins > 0 else { return }
        let cutoff = TimeInterval(mins * 60)
        let now = Date.now
        for tab in tabs where tab.id != activeID && !tab.isHibernated {
            if now.timeIntervalSince(tab.lastActivatedAt) >= cutoff {
                tab.hibernate()
            }
        }
    }

    /// Mark the previously-active tab as just-deactivated and wake the
    /// newly-active one if it's hibernated.
    private func handleActiveChange(from old: UUID?, to new: UUID?) {
        if let old, let prev = tabs.first(where: { $0.id == old }) {
            prev.lastActivatedAt = .now
        }
        if let new, let next = tabs.first(where: { $0.id == new }), next.isHibernated {
            next.wake()
        }
    }

    // MARK: - Tab management

    @discardableResult
    func newTab(url: String? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let b = BrowserTab(configuration: configuration)
        wire(b)
        tabs.append(b)
        activeID = b.id
        if let url, !url.isEmpty { b.navigate(to: url) }
        return b
    }

    /// Close a tab. If it was active, activate the neighbour. Refuses
    /// to close the last tab so the window always has a visible web
    /// view.
    @discardableResult
    func closeTab(id: UUID) -> Bool {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let wasActive = (activeID == id)
        let url = tabs[idx].currentURL?.absoluteString ?? ""
        tabs.remove(at: idx)
        if !url.isEmpty {
            closedURLStack.append(url)
            if closedURLStack.count > closedStackLimit {
                closedURLStack.removeFirst(closedURLStack.count - closedStackLimit)
            }
        }
        if wasActive {
            let next = min(idx, tabs.count - 1)
            activeID = tabs[next].id
        }
        return true
    }

    /// Pop the most recently closed tab's URL and open it in a fresh
    /// tab. No-op if the stack is empty.
    @discardableResult
    func reopenLastClosed() -> BrowserTab? {
        guard let url = closedURLStack.popLast() else { return nil }
        return newTab(url: url)
    }

    var hasReopenableTab: Bool { !closedURLStack.isEmpty }

    /// Activate the tab at `index` (0-based). Returns false if out of
    /// range. Used by ⌘1–⌘9.
    @discardableResult
    func switchTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        activeID = tabs[index].id
        return true
    }

    @discardableResult
    func switchTab(id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    // MARK: - Wiring

    /// Attach delegate + presenter to a freshly-created tab.
    private func wire(_ b: BrowserTab) {
        b.delegate = self
        b.presenter = presenter
        b.downloadStore = downloadStore
    }

    /// Push the latest agent state into every open tab. Called when the
    /// settings reference changes (e.g. mid-session toggle).
    private func applyAgentStateToAllTabs() {
        for tab in tabs { tab.applyAgentStateExternally() }
    }
}

// MARK: - BrowserTabDelegate

extension BrowserWindow: BrowserTabDelegate {

    func browserTabDidFinishNavigation(_ model: BrowserTab,
                                         url: String,
                                         title: String) {
        guard let history = historyRecorder else { return }
        history.record(title: title, url: url)
        // Snapshot the page text for full-text history search.
        // Fire-and-forget; if the page changes before we read, we just
        // get whatever was there first.
        Task { @MainActor [weak history, weak model] in
            guard let history, let model else { return }
            if let text = try? await model.readText(triggerLazyLoad: false), !text.isEmpty {
                history.updateSnippet(url: url, snippet: text)
            }
        }
    }

    func browserTab(_ model: BrowserTab,
                      didRequestNewTabWith configuration: WKWebViewConfiguration) -> WKWebView? {
        // WebKit will load the action's request into the returned web
        // view itself, so we don't navigate here. Wrap the mutation so
        // the tab bar slides in when this is the first new tab.
        var created: BrowserTab?
        withAnimation(.easeInOut(duration: 0.2)) {
            created = newTab(url: nil, configuration: configuration)
        }
        return created?.webView
    }

    func browserTabAgentState(for model: BrowserTab) -> BrowserAgentState {
        guard let s = agentSettings else { return .disabled }
        return BrowserAgentState(
            sensitiveDomains: s.sensitiveDomains,
            confirmEnabled: s.confirmOnSensitive
        )
    }

    func browserTabIsRecording(_ model: BrowserTab) -> Bool {
        recorder?.isRecording ?? false
    }

    func browserTab(_ model: BrowserTab,
                      didCaptureEvent tool: String,
                      args: [String: Any]) {
        recorder?.ingest(tool: tool, args: args)
    }
}
