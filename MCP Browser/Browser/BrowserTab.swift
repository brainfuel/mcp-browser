//
//  BrowserTab.swift
//  MCP Browser
//
//  Owns one WKWebView and exposes an Observable surface (URL, title,
//  loading state, navigation flags) for SwiftUI. All WebKit calls run
//  on the main actor; MCP tool handlers hop here via `MainActor.run`.
//
//  Larger feature areas — DOM tools, downloads, cookies, the agent-
//  cursor / sensitive-submit / recorder bridges — live in dedicated
//  extension files (`BrowserTab+*.swift`) so this file stays focused
//  on lifecycle and navigation.
//

import Foundation
import Observation
import WebKit
import AppKit

@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {

    // MARK: - Identity & web view

    /// Stable identity for tab lists and MCP tab IDs.
    let id = UUID()

    /// The backing web view. WebViewHost installs it into the SwiftUI
    /// tree; tool handlers manipulate it directly. Reassigned by
    /// `hibernate()` / `wake()` so the WebContent process can be torn
    /// down for inactive tabs.
    private(set) var webView: WKWebView

    // MARK: - Observable surface

    var urlString: String = ""
    var currentURL: URL? {
        if isHibernated { return hibernatedURL }
        return webView.url
    }
    var pageTitle: String = ""
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var estimatedProgress: Double = 0

    /// Accessibility-quality summary for the current page. Recomputed
    /// when a navigation finishes loading and surfaced by the URL-bar
    /// indicator. Nil while the page is loading or before a first score.
    var accessibilitySummary: InspectPageTool.Summary?

    /// `@AppStorage` key for the URL-bar accessibility indicator toggle.
    /// Default behavior (when the key is absent) is on.
    static let showAccessibilityIndicatorKey = "showAccessibilityIndicator"

    /// `@AppStorage` key for the cookie consent policy (raw value of
    /// `CookieConsentPolicy`). Default when missing is "decline_optional".
    static let cookieConsentPolicyKey = "cookieConsentPolicy"

    // MARK: - Hibernation

    /// True when the tab's WebContent process has been released. A tiny
    /// placeholder web view stands in to keep the non-optional invariant.
    private(set) var isHibernated: Bool = false

    /// Updated when the tab loses focus (becomes inactive). The window's
    /// sweep uses this to pick stale tabs.
    var lastActivatedAt: Date = .now

    private var hibernatedURL: URL?
    private var hibernatedInteractionState: Data?

    // MARK: - Wiring

    /// Owner of this tab — typically the window's `BrowserWindow`.
    /// Replaces the previous `var on*` closure surface.
    weak var delegate: BrowserTabDelegate?

    /// Surface for native dialogs (submit confirms, file pickers). The
    /// model never imports AppKit beyond what WebKit exposes.
    weak var presenter: BrowserPresenter?

    /// Sink for user-initiated downloads. Set by the owning window so a
    /// single store collects downloads from every tab.
    weak var downloadStore: DownloadStore?

    // MARK: - Internal state

    /// File URL fed to the next `runOpenPanel` callback. Set by the
    /// `upload_file` MCP tool before triggering a click on an input.
    var pendingUpload: URL?

    /// How to auto-respond to JS dialogs (alert/confirm/prompt). When
    /// nil, dialogs are auto-dismissed (alerts complete, confirms
    /// return false, prompts return nil) and just logged.
    struct DialogPolicy {
        enum Action { case accept, dismiss }
        var action: Action
        var promptText: String?
        /// True = applies once then clears. False = persistent.
        var once: Bool
    }
    var dialogPolicy: DialogPolicy?

    /// Recent JS dialog events (newest last). Cleared on navigation.
    struct DialogEvent {
        let kind: String          // "alert" | "confirm" | "prompt"
        let message: String
        let defaultPrompt: String?
        let response: String      // "accepted" | "dismissed"
        let returnedText: String?
        let at: Date
    }
    var dialogLog: [DialogEvent] = []

    /// KVO tokens — held so the observations stay alive.
    private var observations: [NSKeyValueObservation] = []

    // MARK: - Init

    /// `configuration` is non-nil only when WebKit hands us one via
    /// `createWebViewWith`. We always start with a fresh content
    /// controller because the inherited one already has our message
    /// handlers attached (and adding the same handler twice throws).
    /// Shared across every tab WebKit doesn't already hand us a config
    /// for. A single pool lets WebKit consolidate Web Content processes
    /// across tabs instead of standing up a fresh one per tab.
    private static let sharedProcessPool = WKProcessPool()

    init(configuration: WKWebViewConfiguration? = nil) {
        self.webView = Self.makeConfiguredWebView(seed: configuration)
        super.init()
        attach(to: webView)
    }

    /// Build a fully-configured `WKWebView` — script handlers, shared
    /// process pool, default data store. Used by `init` and by `wake()`
    /// when re-creating after hibernation.
    private static func makeConfiguredWebView(seed: WKWebViewConfiguration?) -> WKWebView {
        let config = seed ?? WKWebViewConfiguration()
        if seed == nil {
            config.websiteDataStore = .default()
            config.processPool = sharedProcessPool
        }
        config.userContentController = WKUserContentController()
        for source in [BrowserScripts.networkLog,
                       BrowserScripts.consoleLog,
                       BrowserScripts.sensitiveSubmit,
                       BrowserScripts.recorder,
                       CookieConsentScripts.consentJS] {
            config.userContentController.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        return ContextWebView(frame: .zero, configuration: config)
    }

    /// Wire delegates, message handlers, and KVO onto a freshly built
    /// (or re-built) web view.
    private func attach(to webView: WKWebView) {
        let proxy = ScriptMessageProxy(owner: self)
        webView.configuration.userContentController.add(proxy, name: "mcpConfirmSubmit")
        webView.configuration.userContentController.add(proxy, name: "mcpRecord")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        installKVO()
    }

    // MARK: - Hibernation lifecycle

    /// Drop the WebContent process. Captures URL + interaction state so
    /// `wake()` can resume scroll position, form fields, and the back/
    /// forward stack. No-op if already hibernated.
    func hibernate() {
        guard !isHibernated else { return }
        hibernatedURL = webView.url
        if #available(macOS 12.0, *) {
            hibernatedInteractionState = webView.interactionState as? Data
        }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Replace with a tiny placeholder so the property stays
        // non-optional. The previous web view deallocates and its
        // WebContent process exits.
        self.webView = WKWebView(frame: .zero)
        self.isLoading = false
        self.estimatedProgress = 0
        self.accessibilitySummary = nil
        isHibernated = true
    }

    /// Recreate the web view and restore session state. No-op if not
    /// hibernated.
    func wake() {
        guard isHibernated else { return }
        let fresh = Self.makeConfiguredWebView(seed: nil)
        self.webView = fresh
        attach(to: fresh)
        if #available(macOS 12.0, *), let state = hibernatedInteractionState {
            fresh.interactionState = state
        } else if let url = hibernatedURL {
            fresh.load(URLRequest(url: url))
        }
        hibernatedInteractionState = nil
        hibernatedURL = nil
        isHibernated = false
    }

    /// KVO callbacks fire on the thread the property changes on; for
    /// WKWebView that's the main thread in practice, but we still
    /// dispatch explicitly so the write is guaranteed main-actor
    /// isolated. Sendable copies are extracted before the hop.
    private func installKVO() {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                let value = wv.url?.absoluteString ?? ""
                Task { @MainActor in self?.urlString = value }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                let value = wv.title ?? ""
                Task { @MainActor in self?.pageTitle = value }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                let value = wv.isLoading
                let hasURL = wv.url != nil
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoading = value
                    if value {
                        // Loading started: clear the stale indicator so
                        // the URL-bar dot disappears until the new page
                        // settles and we recompute.
                        self.accessibilitySummary = nil
                    } else if hasURL && !self.isHibernated {
                        await self.recomputeAccessibilitySummary()
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                let value = wv.canGoBack
                Task { @MainActor in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                let value = wv.canGoForward
                Task { @MainActor in self?.canGoForward = value }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                let value = wv.estimatedProgress
                Task { @MainActor in self?.estimatedProgress = value }
            },
        ]
    }

    // MARK: - Cookie consent

    /// Read the current policy from defaults and (a) inject our hide
    /// stylesheet if the policy says so and (b) kick the click-based
    /// rules with the right action token. Called from `didCommit` so
    /// changes to the setting take effect on the next navigation.
    private func applyCookieConsentPolicy() {
        let raw = UserDefaults.standard.string(forKey: Self.cookieConsentPolicyKey)
            ?? CookieConsentPolicy.declineOptional.rawValue
        let policy = CookieConsentPolicy(rawValue: raw) ?? .declineOptional
        guard policy != .off else { return }

        if policy.hidesViaCSS {
            // Inject the hide stylesheet into the page's own document
            // so SPA route changes don't lose it. Idempotent — re-runs
            // on every navigation but skip if already inserted.
            let cssLiteral = BrowserScripts.quote(CookieConsentScripts.hideCSS)
            let hideJS = """
            (function(){
              if (document.getElementById('__mcpConsentHide')) return;
              const s = document.createElement('style');
              s.id = '__mcpConsentHide';
              s.textContent = \(cssLiteral);
              (document.head || document.documentElement).appendChild(s);
            })();
            """
            Task { try? await self.runJS(hideJS) }
        }

        if policy.runsClickLayer {
            // The user script defined `__mcpConsent.run` at documentStart.
            // Kick the polling loop with our action token.
            let action = policy.jsActionToken
            let runStmt = """
            (function(){
              try { window.__mcpConsent && window.__mcpConsent.run('\(action)'); }
              catch(_) {}
            })();
            """
            Task { try? await self.runJS(runStmt) }
        }
    }

    // MARK: - Accessibility scoring

    /// Walk a fresh accessibility tree for the current page and update
    /// `accessibilitySummary`. Called from the `isLoading` KVO when a
    /// navigation settles; failures (script errors, dead web view) leave
    /// the summary cleared rather than poisoning it with stale state.
    func recomputeAccessibilitySummary() async {
        do {
            let tree = try await accessibilityTree(maxDepth: 20, maxNodes: 2000)
            self.accessibilitySummary = InspectPageTool.score(tree: tree)
        } catch {
            self.accessibilitySummary = nil
        }
    }

    // MARK: - Navigation

    /// Accepts a bare domain, a full URL, or a search query, and does
    /// the obvious thing. Returns the URL actually loaded.
    @discardableResult
    func navigate(to raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved = Self.resolveURL(from: trimmed)
        webView.load(URLRequest(url: resolved))
        return resolved
    }

    func goBack()      { webView.goBack() }
    func goForward()   { webView.goForward() }
    func reload()      { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    // MARK: - Zoom

    func zoomIn()    { setZoom(webView.pageZoom * ZoomStore.step) }
    func zoomOut()   { setZoom(webView.pageZoom / ZoomStore.step) }
    func resetZoom() { setZoom(1.0) }

    private func setZoom(_ zoom: Double) {
        let clamped = ZoomStore.clamp(zoom)
        webView.pageZoom = clamped
        ZoomStore.set(clamped, for: webView.url?.host)
    }

    /// Apply the saved zoom for `host`. Called on every navigation
    /// commit so per-site preferences survive across visits.
    fileprivate func applySavedZoom(host: String?) {
        webView.pageZoom = ZoomStore.zoom(for: host)
    }

    /// Find-in-page. Highlights the first match and scrolls to it.
    /// `forward = false` searches backwards. The completion fires with
    /// whether anything matched so the bar can show a not-found state.
    func find(_ query: String,
              forward: Bool = true,
              completion: ((Bool) -> Void)? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(false)
            return
        }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.wraps = true
        config.caseSensitive = false
        webView.find(trimmed, configuration: config) { result in
            completion?(result.matchFound)
        }
    }

    /// Renders raw HTML directly. Useful as an MCP sink so agents can
    /// produce HTML and have it displayed without hosting it.
    func renderHTML(_ html: String, baseURL: URL? = nil) {
        webView.loadHTMLString(html, baseURL: baseURL ?? URL(string: "about:blank"))
    }

    // MARK: - JS bridge

    /// Evaluate a JS expression and return the result as a string.
    func evalJS(_ script: String) async throws -> String {
        let result = try await runJS(script)
        return Self.stringify(result)
    }

    /// Best-effort extraction of page text. Scrolls the document end to
    /// end to trigger IntersectionObserver-based lazy hydration, reads
    /// `innerText` from the main document and walks same-origin iframes
    /// (falling back to `textContent`), then restores the scroll
    /// position. Cross-origin frames are skipped silently.
    enum ReadTextMode: String { case visible, all }

    func readText(mode: ReadTextMode = .visible, triggerLazyLoad: Bool = true) async throws -> String {
        if triggerLazyLoad {
            let metricsJS = """
            ({
              x: window.scrollX, y: window.scrollY,
              h: Math.max(
                document.body ? document.body.scrollHeight : 0,
                document.documentElement ? document.documentElement.scrollHeight : 0
              ),
              step: Math.max(window.innerHeight || 800, 400)
            })
            """
            if let metrics = try await runJS(metricsJS) as? [String: Any],
               let height = (metrics["h"] as? NSNumber)?.doubleValue,
               let step = (metrics["step"] as? NSNumber)?.doubleValue,
               height > 0, step > 0 {
                let origX = (metrics["x"] as? NSNumber)?.doubleValue ?? 0
                let origY = (metrics["y"] as? NSNumber)?.doubleValue ?? 0
                var y = 0.0
                while y < height {
                    _ = try? await runJS("window.scrollTo(0, \(y))")
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    y += step
                }
                _ = try? await runJS("window.scrollTo(0, \(height))")
                try? await Task.sleep(nanoseconds: 120_000_000)
                _ = try? await runJS("window.scrollTo(\(origX), \(origY))")
            }
        }

        let visibleJS = """
        (() => {
          const parts = [];
          const visit = (doc) => {
            if (!doc || !doc.body) return;
            const txt = doc.body.innerText || doc.body.textContent || '';
            if (txt) parts.push(txt);
            const frames = doc.querySelectorAll('iframe, frame');
            for (const f of frames) {
              try { visit(f.contentDocument); } catch (_) { /* cross-origin */ }
            }
          };
          visit(document);
          return parts.join('\\n\\n');
        })()
        """

        // Recursive walk over every node — including shadow roots and
        // same-origin iframes — collecting visible text, image alt,
        // aria-label, button/input labels. Skips <script>/<style>.
        // Output is line-deduped to avoid the repetition that comes
        // from textContent's lack of layout-aware spacing.
        let allJS = """
        (() => {
          const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE']);
          const out = [];
          const seen = new Set();
          const push = (s) => {
            if (!s) return;
            const t = String(s).replace(/\\s+/g, ' ').trim();
            if (!t || seen.has(t)) return;
            seen.add(t);
            out.push(t);
          };
          const visit = (node) => {
            if (!node) return;
            if (node.nodeType === Node.TEXT_NODE) {
              push(node.nodeValue);
              return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;
            if (node.nodeType === Node.ELEMENT_NODE) {
              if (SKIP.has(node.tagName)) return;
              const tag = node.tagName;
              if (tag === 'IMG' && node.alt) push(node.alt);
              if (tag === 'INPUT') {
                if (node.placeholder) push(node.placeholder);
                if (node.value && (node.type === 'submit' || node.type === 'button')) push(node.value);
              }
              const aria = node.getAttribute && node.getAttribute('aria-label');
              if (aria) push(aria);
              if (tag === 'IFRAME' || tag === 'FRAME') {
                try { visit(node.contentDocument); } catch (_) { if (node.src) push('[iframe: ' + node.src + ']'); }
                return;
              }
              if (node.shadowRoot) visit(node.shadowRoot);
            }
            for (let c = node.firstChild; c; c = c.nextSibling) visit(c);
          };
          visit(document);
          return out.join('\\n');
        })()
        """

        let readJS = mode == .all ? allJS : visibleJS
        let result = try await runJS(readJS)
        return (result as? String) ?? ""
    }

    /// Continuation wrapper around `evaluateJavaScript`. The async
    /// overload that takes content world / frame parameters has
    /// overload-resolution issues with the Void-returning callback
    /// variant, so we adapt the legacy callback API by hand.
    func runJS(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: value) }
            }
        }
    }

    // MARK: - Helpers

    /// Turn user input into a URL. Heuristics mirror Safari's unified
    /// address bar: looks like a URL? load it. Has a dot and no spaces?
    /// treat as bare domain. Otherwise Google search.
    static func resolveURL(from raw: String) -> URL {
        if let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        let hasDot = raw.contains(".")
        let hasSpace = raw.contains(" ")
        if hasDot && !hasSpace, let url = URL(string: "https://\(raw)") {
            return url
        }
        return SearchEngine.current.searchURL(for: raw)
    }

    /// Render an arbitrary JS value as a Swift string. Used by `evalJS`
    /// so agents always get a textual result without needing to handle
    /// every NSNumber / dictionary case themselves.
    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    /// Poll a main-actor predicate until it returns true or `timeoutMs`
    /// elapses. Used by the various `wait_for` MCP tools.
    func poll(timeoutMs: Int,
              intervalMs: Int = 100,
              _ check: @escaping @MainActor () async -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if await check() { return true }
            try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
        return await check()
    }

    /// Pick a non-colliding file name inside `dir`, appending `-N` to
    /// the stem until we find a free slot.
    static func uniqueDestination(in dir: URL, preferred: String) -> URL {
        var candidate = dir.appendingPathComponent(preferred)
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (preferred as NSString).pathExtension
        let stem = (preferred as NSString).deletingPathExtension
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
            candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

// MARK: - Errors

enum BrowserError: LocalizedError {
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .snapshotFailed: return "failed to take page snapshot"
        }
    }
}

// MARK: - Navigation delegate

extension BrowserTab: WKNavigationDelegate {

    /// HTTP Basic / Digest / NTLM credential prompt. Server-trust and
    /// client-cert challenges fall back to the system default — TLS
    /// pinning and identity selection are out of scope for this batch.
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        let credentialMethods: Set<String> = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
        ]
        guard credentialMethods.contains(method), let presenter else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let realm = challenge.protectionSpace.realm ?? ""
        let isProxy = challenge.protectionSpace.isProxy()
        Task { @MainActor in
            if let credential = await presenter.requestHTTPCredential(
                host: host, realm: realm, isProxy: isProxy
            ) {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    /// Hand non-web schemes (mailto:, tel:, sms:, facetime:, app deep
    /// links, etc.) to the system so the OS can route them to the right
    /// handler. Plain http/https stays in WebKit. `about:` and `data:`
    /// are kept too — they're frequently used by the engine itself.
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file"]
        if webSchemes.contains(scheme) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    /// Promote responses WebKit can't render (or that arrive with
    /// `Content-Disposition: attachment`) into `WKDownload`s so they
    /// land in the Downloads list instead of showing a blank page.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let canShow = navigationResponse.canShowMIMEType
        var isAttachment = false
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition") {
            isAttachment = disp.lowercased().contains("attachment")
        }
        if !canShow || isAttachment {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        let url = navigationResponse.response.url
        downloadStore?.attach(download, sourceURL: url, suggestedFilename: navigationResponse.response.suggestedFilename)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        downloadStore?.attach(download, sourceURL: navigationAction.request.url, suggestedFilename: nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        dialogLog.removeAll()
        // Refresh per-page agent state so the sensitive-submit script
        // and recorder gate have the current values when the page
        // wires up.
        applyAgentStateToPage()
        applyRecordingStateToPage()
        applySavedZoom(host: webView.url?.host)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString, !url.isEmpty else { return }
        // WKWebView updates `title` slightly after didFinish — grab whatever's
        // there; the history row is happy to show the URL if it's empty.
        delegate?.browserTabDidFinishNavigation(self, url: url, title: webView.title ?? "")
    }
}

// MARK: - UI delegate (new-tab routing)

extension BrowserTab: WKUIDelegate {

    /// target=_blank links and "Open Link in New Tab" both route here.
    /// If the owning window has wired `onRequestNewTab`, we return a
    /// fresh tab's web view so WebKit loads the navigation into it;
    /// otherwise we fall back to loading in the current view.
    func webView(_ webView: WKWebView,
                 createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let new = delegate?.browserTab(self, didRequestNewTabWith: config) {
            return new
        }
        if let url = action.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    /// alert(). Auto-completes; logs to `dialogLog`. Pre-set
    /// `dialogPolicy` via the `dialog` MCP tool to control behavior.
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let policy = consumeDialogPolicy()
        let response: String = (policy?.action == .dismiss) ? "dismissed" : "accepted"
        dialogLog.append(.init(
            kind: "alert", message: message, defaultPrompt: nil,
            response: response, returnedText: nil, at: Date()
        ))
        completionHandler()
    }

    /// confirm(). Returns true on accept, false on dismiss (default).
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let policy = consumeDialogPolicy()
        let accept = (policy?.action == .accept)
        dialogLog.append(.init(
            kind: "confirm", message: message, defaultPrompt: nil,
            response: accept ? "accepted" : "dismissed",
            returnedText: nil, at: Date()
        ))
        completionHandler(accept)
    }

    /// prompt(). Returns the policy's promptText on accept, nil on dismiss.
    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let policy = consumeDialogPolicy()
        let accept = (policy?.action == .accept)
        let text: String? = accept ? (policy?.promptText ?? defaultText ?? "") : nil
        dialogLog.append(.init(
            kind: "prompt", message: prompt, defaultPrompt: defaultText,
            response: accept ? "accepted" : "dismissed",
            returnedText: text, at: Date()
        ))
        completionHandler(text)
    }

    private func consumeDialogPolicy() -> DialogPolicy? {
        guard let p = dialogPolicy else { return nil }
        if p.once { dialogPolicy = nil }
        return p
    }

    /// Camera / microphone permission prompt. Forwarded to the
    /// presenter so the model layer doesn't import AppKit dialog code.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let presenter else {
            decisionHandler(.prompt)
            return
        }
        let wantsCamera = (type == .camera || type == .cameraAndMicrophone)
        let wantsMic    = (type == .microphone || type == .cameraAndMicrophone)
        let host = origin.host
        Task { @MainActor in
            switch await presenter.requestMediaCapture(
                host: host, wantsCamera: wantsCamera, wantsMicrophone: wantsMic
            ) {
            case .grant:  decisionHandler(.grant)
            case .deny:   decisionHandler(.deny)
            case .prompt: decisionHandler(.prompt)
            }
        }
    }
}

// MARK: - Script message bridge

/// Forwards `WKScriptMessageHandler` callbacks to a weakly-held
/// BrowserTab. Keeps the content controller's strong reference from
/// creating a retain cycle with the model.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserTab?

    init(owner: BrowserTab) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "mcpConfirmSubmit":
            guard let key = body["key"] as? String else { return }
            let action = body["action"] as? String ?? ""
            let host = body["host"] as? String ?? ""
            Task { @MainActor [weak self] in
                self?.owner?.presentSubmitConfirmation(key: key, action: action, host: host)
            }
        case "mcpRecord":
            guard let kind = body["kind"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.owner?.handleRecordedEvent(kind: kind, payload: body)
            }
        default:
            break
        }
    }
}

// MARK: - Small utility

extension String {
    /// `nil` when the string is empty, else `self`. Used to chain
    /// fallbacks like `suggestedFilename ?? url.lastPathComponent.nonEmpty ?? "download"`.
    var nonEmpty: String? { isEmpty ? nil : self }
}
