//
//  BrowserTab+Upload.swift
//  MCP Browser
//
//  Implements `upload_file`. WebKit doesn't expose a programmatic
//  file-upload API, so the strategy is:
//
//    1. The MCP tool sets `pendingUpload` to the agent-supplied path.
//    2. We click the input[type=file] which triggers WebKit's file
//       picker.
//    3. Our WKUIDelegate intercepts the picker and returns the
//       pending file URL instead of presenting an NSOpenPanel.
//
//  When no upload is pending we fall back to the standard NSOpenPanel
//  so manual uploads still work.
//

import Foundation
import WebKit

extension BrowserTab {

    /// Stage a file for the next file-input click. Returns true if the
    /// click landed; false if the selector didn't match (in which case
    /// the staged path is cleared so the next manual click isn't
    /// hijacked).
    func uploadFile(selector: String, path: String) async throws -> Bool {
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }

        pendingUpload = fileURL
        let clicked = try await click(selector: selector)
        if !clicked { pendingUpload = nil }
        return clicked
    }

    /// File-picker hook on the existing WKUIDelegate conformance. With
    /// a pending upload, fulfill the picker silently; otherwise hand
    /// off to the presenter so the model itself stays AppKit-free.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        if let pending = pendingUpload {
            pendingUpload = nil
            completionHandler([pending])
            return
        }
        let allowMultiple = parameters.allowsMultipleSelection
        Task { @MainActor [weak self] in
            let urls = await self?.presenter?.chooseFiles(allowMultiple: allowMultiple)
            completionHandler(urls)
        }
    }
}
