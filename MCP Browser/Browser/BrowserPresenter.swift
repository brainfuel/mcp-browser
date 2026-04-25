//
//  BrowserPresenter.swift
//  MCP Browser
//
//  Native UI surface used by BrowserTab. Pulled out of the model so
//  it can run headless (e.g. tests) and so the model layer doesn't
//  block on `runModal()`. The default implementation wraps NSAlert and
//  NSOpenPanel.
//

import Foundation
import AppKit

@MainActor
protocol BrowserPresenter: AnyObject {
    /// Ask the user to confirm a form submission on a sensitive host.
    func confirmSubmit(host: String, action: String) async -> Bool

    /// Present a native open panel for a file input. Returns nil when
    /// the user cancels.
    func chooseFiles(allowMultiple: Bool) async -> [URL]?

    /// Camera and/or microphone access requested by a page. `.grant`
    /// allows for the rest of the page lifetime, `.deny` rejects, and
    /// `.prompt` defers to WebKit's default behavior (which will
    /// usually re-prompt). The default implementation surfaces a
    /// native alert.
    func requestMediaCapture(host: String,
                             wantsCamera: Bool,
                             wantsMicrophone: Bool) async -> MediaCaptureDecision

    /// HTTP Basic / Digest / NTLM challenge. Returns nil to cancel the
    /// auth (page sees a 401 / load failure). The presenter is
    /// responsible for the credential dialog.
    func requestHTTPCredential(host: String,
                               realm: String,
                               isProxy: Bool) async -> URLCredential?
}

enum MediaCaptureDecision {
    case grant
    case deny
    case prompt
}

/// Default implementation backed by AppKit. App wires this in at
/// startup; tests can substitute their own.
@MainActor
final class DefaultBrowserPresenter: BrowserPresenter {

    func confirmSubmit(host: String, action: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Submit form on \(host)?"
        alert.informativeText = action.isEmpty
            ? "This page is on your sensitive-domain list."
            : "Destination: \(action)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func chooseFiles(allowMultiple: Bool) async -> [URL]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[URL]?, Never>) in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = allowMultiple
            panel.begin { response in
                cont.resume(returning: response == .OK ? panel.urls : nil)
            }
        }
    }

    func requestMediaCapture(host: String,
                             wantsCamera: Bool,
                             wantsMicrophone: Bool) async -> MediaCaptureDecision {
        let kinds: String
        switch (wantsCamera, wantsMicrophone) {
        case (true, true):  kinds = "camera and microphone"
        case (true, false): kinds = "camera"
        case (false, true): kinds = "microphone"
        case (false, false): return .prompt
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use your \(kinds)?"
        alert.informativeText = "The page can capture audio and/or video while it's open."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn ? .grant : .deny
    }

    func requestHTTPCredential(host: String,
                               realm: String,
                               isProxy: Bool) async -> URLCredential? {
        let alert = NSAlert()
        alert.messageText = isProxy
            ? "Sign in to proxy \(host)"
            : "Sign in to \(host)"
        alert.informativeText = realm.isEmpty ? "Enter your username and password." : "Realm: \(realm)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        // Stack a username/password pair into the alert's accessory.
        let userField = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        userField.placeholderString = "Username"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        passField.placeholderString = "Password"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        container.addSubview(userField)
        container.addSubview(passField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = userField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let user = userField.stringValue
        let pass = passField.stringValue
        if user.isEmpty && pass.isEmpty { return nil }
        return URLCredential(user: user, password: pass, persistence: .forSession)
    }
}
