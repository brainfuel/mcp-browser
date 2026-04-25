//
//  ContentView.swift
//  MCP Browser
//
//  Top-level view for one browser window. Owns a
//  `BrowserWindowViewModel`, lays out the bookmarks bar / tab bar /
//  WebViewHost, hangs the URL-suggestion overlay, and configures the
//  unified toolbar. All non-trivial state and behavior lives in the
//  view model; this file is only layout + binding.
//

import SwiftUI

struct ContentView: View {

    @State private var viewModel = BrowserWindowViewModel()
    @FocusState private var urlFieldFocused: Bool

    @Environment(MCPCoordinator.self) private var coordinator
    @Environment(BookmarkStore.self)  private var bookmarks
    @Environment(HistoryStore.self)   private var history
    @Environment(Recorder.self)       private var recorder

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
            if vm.bookmarksBarVisible {
                BookmarksBarView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if vm.hasMultipleTabs {
                VStack(spacing: 0) {
                    Divider()
                    TabBarStrip(
                        window: vm.window,
                        onSwitch: { vm.switchTab(id: $0) },
                        onClose:  { vm.closeTab(id: $0) }
                    )
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            WebViewHost()
                .frame(minWidth: 800, minHeight: 520)
        }
        .animation(.easeInOut(duration: 0.18), value: vm.bookmarksBarVisible)
        .animation(.easeInOut(duration: 0.18), value: vm.hasMultipleTabs)
        .frame(minWidth: 960, minHeight: 600)
        .overlay(alignment: .top) {
            if !vm.suggestions.isEmpty {
                URLSuggestionList(
                    suggestions: vm.suggestions,
                    selection: vm.suggestionSelection,
                    onPick: {
                        vm.pickSuggestion($0)
                        urlFieldFocused = false
                    }
                )
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .environment(vm.window)
        .modifier(OptionalBrowserEnvironment(browser: vm.browser))
        .publishBrowserActions(vm.commandActions)
        .background(
            // Bridge NSWindow key/close events so MCP follows focus.
            WindowFocusObserver(
                onBecomeKey: { coordinator.setActive(vm.window) },
                onClose:     { coordinator.unregister(vm.window) }
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            vm.setUp(
                coordinator: coordinator,
                bookmarks: bookmarks,
                history: history,
                recorder: recorder
            )
        }
        .onChange(of: vm.window.activeID) { _, _ in
            vm.syncURLFieldToActiveTab()
            urlFieldFocused = false
        }
        .onChange(of: vm.browser?.urlString ?? "") { _, new in
            if !urlFieldFocused { vm.urlField = new }
        }
        .onChange(of: vm.focusURLToken) { _, _ in
            urlFieldFocused = true
        }
        .toolbar {
            navigationGroup(vm: vm)
            urlBarItem(vm: vm)
            primaryActionsGroup(vm: vm)
        }
        .sheet(isPresented: $vm.showingSettings) {
            if let browser = vm.browser { SettingsView().environment(browser) }
        }
        .sheet(isPresented: $vm.showingBookmarks) {
            if let browser = vm.browser { BookmarksView().environment(browser) }
        }
        .sheet(isPresented: $vm.showingHistory) {
            if let browser = vm.browser { HistoryView().environment(browser) }
        }
    }

    // MARK: - Toolbar groups

    @ToolbarContentBuilder
    private func navigationGroup(vm: BrowserWindowViewModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: vm.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!(vm.browser?.canGoBack ?? false))
            .help("Back")

            Button(action: vm.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!(vm.browser?.canGoForward ?? false))
            .help("Forward")

            Button {
                if vm.browser?.isLoading == true { vm.stop() } else { vm.reload() }
            } label: {
                Image(systemName: vm.browser?.isLoading == true ? "xmark" : "arrow.clockwise")
            }
            .help(vm.browser?.isLoading == true ? "Stop" : "Reload")
        }
    }

    @ToolbarContentBuilder
    private func urlBarItem(vm: BrowserWindowViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            URLBarField(
                vm: vm,
                focused: $urlFieldFocused
            )
        }
    }

    @ToolbarContentBuilder
    private func primaryActionsGroup(vm: BrowserWindowViewModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: vm.newTab) {
                Image(systemName: "plus")
            }
            .help("New tab")

            Button(action: vm.openBookmarks) {
                Image(systemName: "book")
            }
            .help("Bookmarks")

            Button(action: vm.openHistory) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("History")

            Button(action: vm.openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
    }
}

// MARK: - URL bar

/// The URL field plus the bookmark star and loading indicator that
/// share the principal toolbar slot. Pulled out so ContentView's
/// `body` reads as plain layout.
private struct URLBarField: View {
    @Bindable var vm: BrowserWindowViewModel
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 8)

            HStack(spacing: 6) {
                pageFavicon
                TextField("Search or enter address", text: $vm.urlField)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        vm.commitURLField()
                        focused = false
                    }
                    .onChange(of: vm.urlField) { _, _ in
                        vm.resetSuggestionSelection()
                    }
                    .onKeyPress(.downArrow) {
                        guard !vm.suggestions.isEmpty else { return .ignored }
                        vm.selectNextSuggestion()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !vm.suggestions.isEmpty else { return .ignored }
                        vm.selectPreviousSuggestion()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if focused { focused = false; return .handled }
                        return .ignored
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .frame(minWidth: 280, idealWidth: 560)

            Button(action: vm.toggleBookmark) {
                Image(systemName: vm.isCurrentBookmarked ? "star.fill" : "star")
                    .foregroundStyle(vm.isCurrentBookmarked ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!vm.hasCurrentURL)
            .help(vm.isCurrentBookmarked ? "Remove bookmark" : "Bookmark this page")

            if vm.browser?.isLoading == true {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Favicon for the currently displayed page, draggable so the user
    /// can drop the page into a folder on the bookmarks bar (Safari-style).
    @ViewBuilder
    private var pageFavicon: some View {
        let urlString = vm.browser?.urlString ?? ""
        let title = vm.browser?.pageTitle ?? ""
        if urlString.isEmpty {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        } else {
            FaviconImage(urlString: urlString, size: 14)
                .draggable(PageDragPayload(title: title, url: urlString))
                .help("Drag to bookmark this page")
        }
    }
}

// MARK: - Tab strip

/// The horizontal row of tab chips shown when more than one tab is
/// open. Pure presentation: gets `BrowserWindow` for state and two
/// callbacks for switch/close.
private struct TabBarStrip: View {
    let window: BrowserWindow
    let onSwitch: (UUID) -> Void
    let onClose:  (UUID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(window.tabs) { tab in
                TabChip(
                    tab: tab,
                    isActive: tab.id == window.activeID,
                    canClose: window.tabs.count > 1,
                    onSwitch: { onSwitch(tab.id) },
                    onClose:  { onClose(tab.id) }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(.regularMaterial)
    }
}

private struct TabChip: View {
    let tab: BrowserTab
    let isActive: Bool
    let canClose: Bool
    let onSwitch: () -> Void
    let onClose:  () -> Void

    var body: some View {
        let label = tab.pageTitle.isEmpty ? (tab.currentURL?.host ?? "New Tab") : tab.pageTitle

        HStack(spacing: 6) {
            Button(action: onSwitch) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - URL suggestion dropdown

private struct URLSuggestionList: View {
    let suggestions: [URLSuggestion]
    let selection: Int
    let onPick: (URLSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                row(suggestion, isSelected: index == selection)
                    .onTapGesture { onPick(suggestion) }
                if index < suggestions.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 640)
        .padding(.horizontal, 24)
    }

    private func row(_ s: URLSuggestion, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.source == .bookmark ? "star.fill" : "clock")
                .foregroundStyle(s.source == .bookmark ? Color.yellow : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title.isEmpty ? s.url : s.title).lineLimit(1)
                Text(s.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 4)
        )
    }
}

// MARK: - Environment plumbing

/// Injects the active tab's `BrowserTab` into the environment so child
/// views ( `BookmarksBarView`, sheets ) keep working with their existing
/// `@Environment(BrowserTab.self)` declarations. No-op when no tab
/// exists yet (window just opened).
private struct OptionalBrowserEnvironment: ViewModifier {
    let browser: BrowserTab?
    func body(content: Content) -> some View {
        if let browser {
            content.environment(browser)
        } else {
            content
        }
    }
}

#Preview {
    let agent = AgentSettings()
    let log = ActionLog()
    let rec = Recorder()
    return ContentView()
        .environment(MCPCoordinator(
            agentSettings: agent,
            actionLog: log,
            recorder: rec,
            presenter: DefaultBrowserPresenter()
        ))
        .environment(BookmarkStore())
        .environment(HistoryStore())
        .environment(agent)
        .environment(log)
        .environment(rec)
}
