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
}
