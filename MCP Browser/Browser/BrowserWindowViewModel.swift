//
//  BrowserWindowViewModel.swift
//  MCP Browser
//
//  Per-window view-model. Owns the `BrowserWindow` (tab container),
//  URL-bar text, suggestion selection, sheet visibility flags, and the
//  bookmarks-bar preference, plus the actions the chrome and the
//  native menu bar invoke. Keeps `ContentView` focused on layout.
//

import Foundation
import Observation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class BrowserWindowViewModel {

    // MARK: - Owned state

    /// The window's tab container — `BrowserWindow` is its own
    /// `@Observable`; the view model holds it so external collaborators
    /// (the MCP coordinator, the WebViewHost) can keep talking to it
    /// directly.
    let window = BrowserWindow()

    var urlField: String = ""
    var suggestionSelection: Int = 0

    var showingSettings: Bool = false
    var showingBookmarks: Bool = false
    var showingHistory: Bool = false

    /// Persisted preference. Mirrors a `UserDefaults` key so the toggle
    /// survives launches and stays in sync across windows.
    var showsBookmarksBar: Bool {
        didSet { UserDefaults.standard.set(showsBookmarksBar, forKey: Self.bookmarksBarKey) }
    }
    private static let bookmarksBarKey = "showsBookmarksBar"

    // MARK: - Dependencies (set by `setUp`)

    private weak var coordinator: MCPCoordinator?
    private weak var bookmarks: BookmarkStore?
    private weak var history: HistoryStore?
    private weak var recorder: Recorder?

    // MARK: - Init

    init() {
        showsBookmarksBar = UserDefaults.standard.object(forKey: Self.bookmarksBarKey) as? Bool ?? true
    }

    /// One-shot wiring from `ContentView.onAppear`. Pulls dependencies
    /// out of the SwiftUI environment and registers with the
    /// coordinator so the MCP server can find this window.
    func setUp(coordinator: MCPCoordinator,
               bookmarks: BookmarkStore,
               history: HistoryStore,
               recorder: Recorder,
               port: UInt16 = 8833) {
        self.coordinator = coordinator
        self.bookmarks = bookmarks
        self.history = history
        self.recorder = recorder
        window.historyRecorder = history
        coordinator.register(tabs: window, port: port)
        urlField = browser?.urlString ?? ""
    }

    // MARK: - Derived state

    var browser: BrowserTab? { window.active }
    var hasMultipleTabs: Bool { window.tabs.count > 1 }

    var currentURLString: String { browser?.currentURL?.absoluteString ?? "" }
    var hasCurrentURL: Bool { !currentURLString.isEmpty }

    var isCurrentBookmarked: Bool {
        guard hasCurrentURL else { return false }
        return bookmarks?.isBookmarked(url: currentURLString) ?? false
    }

    var bookmarksBarVisible: Bool {
        showsBookmarksBar && (bookmarks?.barBookmarks.isEmpty == false)
    }

    /// Bookmarks + history rows whose title or URL match the current
    /// URL-field text. AND-of-terms, case-insensitive, capped at 8.
    var suggestions: [URLSuggestion] {
        let raw = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        if raw.lowercased() == currentURLString.lowercased() { return [] }

        let terms = raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let limit = 8
        var out: [URLSuggestion] = []
        var seen = Set<String>()

        if let bookmarks {
            for bm in bookmarks.bookmarks where out.count < limit {
                let hay = (bm.title + " " + bm.url).lowercased()
                if terms.allSatisfy({ hay.contains($0) }), seen.insert(bm.url).inserted {
                    out.append(URLSuggestion(url: bm.url, title: bm.title, source: .bookmark))
                }
            }
        }
        if let history {
            for entry in history.entries where out.count < limit {
                let hay = (entry.title + " " + entry.url).lowercased()
                if terms.allSatisfy({ hay.contains($0) }), seen.insert(entry.url).inserted {
                    out.append(URLSuggestion(url: entry.url, title: entry.title, source: .history))
                }
            }
        }
        return out
    }

    // MARK: - Tab actions

    func newTab() {
        withAnimation(.easeInOut(duration: 0.2)) { _ = window.newTab(url: nil) }
    }

    func switchTab(id: UUID) {
        _ = window.switchTab(id: id)
    }

    func closeTab(id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) { _ = window.closeTab(id: id) }
    }

    /// Close the focused tab; if it's the last one, close the window.
    func closeActiveTabOrWindow() {
        if hasMultipleTabs, let id = window.activeID {
            closeTab(id: id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    // MARK: - Navigation actions

    func reload()    { browser?.reload() }
    func stop()      { browser?.stopLoading() }
    func goBack()    { browser?.goBack() }
    func goForward() { browser?.goForward() }

    // MARK: - URL field actions

    func selectNextSuggestion() {
        guard !suggestions.isEmpty else { return }
        suggestionSelection = min(suggestionSelection + 1, suggestions.count - 1)
    }

    func selectPreviousSuggestion() {
        guard !suggestions.isEmpty else { return }
        suggestionSelection = max(suggestionSelection - 1, 0)
    }

    func resetSuggestionSelection() { suggestionSelection = 0 }

    /// Enter handler. With an arrow-keyed selection, navigate to it;
    /// otherwise fall through to "treat as URL or search".
    func commitURLField() {
        if !suggestions.isEmpty, suggestionSelection > 0 {
            pickSuggestion(suggestions[suggestionSelection])
            return
        }
        recorder?.recordManualNavigate(url: urlField)
        browser?.navigate(to: urlField)
    }

    func pickSuggestion(_ suggestion: URLSuggestion) {
        urlField = suggestion.url
        recorder?.recordManualNavigate(url: suggestion.url)
        browser?.navigate(to: suggestion.url)
    }

    /// Reset the URL field and re-sync to the active tab. Called when
    /// the active tab changes.
    func syncURLFieldToActiveTab() {
        urlField = browser?.urlString ?? ""
    }

    // MARK: - Bookmark / sheet actions

    func toggleBookmark() {
        guard let bookmarks, let browser, hasCurrentURL else { return }
        bookmarks.toggle(title: browser.pageTitle, url: currentURLString)
    }

    func toggleBookmarksBar() { showsBookmarksBar.toggle() }

    func openSettings()  { showingSettings = true }
    func openBookmarks() { showingBookmarks = true }
    func openHistory()   { showingHistory = true }

    // MARK: - Save as PDF

    /// Present an `NSSavePanel` and write the active tab's PDF to the
    /// chosen URL. Errors surface as a modal alert. Owns the AppKit
    /// bits because this is a window-scoped chrome action — the
    /// `BrowserPresenter` is reserved for things triggered *from* the
    /// model layer.
    func savePagePDF() {
        guard let browser else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = browser.suggestedPDFFilename
        panel.canCreateDirectories = true
        panel.title = "Save Page as PDF"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    _ = try await browser.exportPDF(to: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save PDF"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Menu bar bridge

    /// Snapshot of menu actions + flags for the focused window. Read by
    /// `AppCommands` via `@FocusedValue`.
    var commandActions: BrowserCommandActions {
        BrowserCommandActions(
            newTab:                { [weak self] in self?.newTab() },
            closeActiveTab:        { [weak self] in self?.closeActiveTabOrWindow() },
            reload:                { [weak self] in self?.reload() },
            stop:                  { [weak self] in self?.stop() },
            goBack:                { [weak self] in self?.goBack() },
            goForward:             { [weak self] in self?.goForward() },
            toggleBookmarkCurrent: { [weak self] in self?.toggleBookmark() },
            openBookmarks:         { [weak self] in self?.openBookmarks() },
            openHistory:           { [weak self] in self?.openHistory() },
            openSettings:          { [weak self] in self?.openSettings() },
            savePagePDF:           { [weak self] in self?.savePagePDF() },
            toggleBookmarksBar:    { [weak self] in self?.toggleBookmarksBar() },
            canGoBack:           browser?.canGoBack ?? false,
            canGoForward:        browser?.canGoForward ?? false,
            isLoading:           browser?.isLoading ?? false,
            hasCurrentURL:       hasCurrentURL,
            isCurrentBookmarked: isCurrentBookmarked,
            bookmarksBarVisible: bookmarksBarVisible,
            canShowBookmarksBar: bookmarks?.barBookmarks.isEmpty == false
        )
    }
}

// MARK: - Suggestion row

/// One row in the URL-bar predictive dropdown. `url` is the stable id
/// so duplicate entries that come from both bookmarks and history
/// collapse.
struct URLSuggestion: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let title: String
    let source: Source

    enum Source { case bookmark, history }
}
