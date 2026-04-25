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
    /// tree; tool handlers manipulate it directly.
    let webView: WKWebView

    // MARK: - Observable surface

    var urlString: String = ""
    var currentURL: URL? { webView.url }
    var pageTitle: String = ""
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var estimatedProgress: Double = 0

    // MARK: - Wiring

    /// Owner of this tab — typically the window's `BrowserWindow`.
    /// Replaces the previous `var on*` closure surface.
    weak var delegate: BrowserTabDelegate?

    /// Surface for native dialogs (submit confirms, file pickers). The
    /// model never imports AppKit beyond what WebKit exposes.
    weak var presenter: BrowserPresenter?

    // MARK: - Internal state

    /// File URL fed to the next `runOpenPanel` callback. Set by the
    /// `upload_file` MCP tool before triggering a click on an input.
    var pendingUpload: URL?

    /// KVO tokens — held so the observations stay alive.
    private var observations: [NSKeyValueObservation] = []

    // MARK: - Init

    /// `configuration` is non-nil only when WebKit hands us one via
    /// `createWebViewWith`. We always start with a fresh content
    /// controller because the inherited one already has our message
    /// handlers attached (and adding the same handler twice throws).
    init(configuration: WKWebViewConfiguration? = nil) {
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil {
            config.websiteDataStore = .default()
        }
        config.userContentController = WKUserContentController()

        for source in [BrowserScripts.networkLog,
                       BrowserScripts.sensitiveSubmit,
                       BrowserScripts.recorder] {
            config.userContentController.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        self.webView = ContextWebView(frame: .zero, configuration: config)
        super.init()

        let proxy = ScriptMessageProxy(owner: self)
        config.userContentController.add(proxy, name: "mcpConfirmSubmit")
        config.userContentController.add(proxy, name: "mcpRecord")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        installKVO()
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
                Task { @MainActor in self?.isLoading = value }
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

    /// Best-effort extraction of visible text via `document.body.innerText`.
    func readText() async throws -> String {
        let result = try await runJS("document.body ? document.body.innerText : ''")
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
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return URL(string: "https://www.google.com/search?q=\(encoded)")!
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Refresh per-page agent state so the sensitive-submit script
        // and recorder gate have the current values when the page
        // wires up.
        applyAgentStateToPage()
        applyRecordingStateToPage()
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
