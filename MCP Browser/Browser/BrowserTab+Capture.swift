//
//  BrowserTab+Capture.swift
//  MCP Browser
//
//  Visual capture: PNG snapshot for the agent cursor / PiP / `screenshot`
//  tool, and PDF export for `pdf_export`.
//

import Foundation
import WebKit
import AppKit

extension BrowserTab {

    /// Full-viewport PNG snapshot of the current page state.
    func screenshotPNG() async throws -> Data {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: config)
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw BrowserError.snapshotFailed
        }
        return png
    }

    /// Render the current page to PDF and write it to disk. With `to`
    /// nil, falls back to a unique name inside `~/Downloads` (used by
    /// the `pdf_export` MCP tool). Returns the destination URL.
    func exportPDF(filename: String? = nil, to destination: URL? = nil) async throws -> URL {
        let data = try await renderPDF()
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let base = filename ?? (pageTitle.nonEmpty ?? "page") + ".pdf"
            let withExt = base.hasSuffix(".pdf") ? base : base + ".pdf"
            dest = Self.uniqueDestination(in: downloads, preferred: withExt)
        }
        try data.write(to: dest)
        return dest
    }

    /// Suggested filename for save panels, derived from the page title
    /// (or the URL host as a fallback).
    var suggestedPDFFilename: String {
        let stem = pageTitle.nonEmpty
            ?? currentURL?.host
            ?? "page"
        return stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            + ".pdf"
    }

    private func renderPDF() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            webView.createPDF { result in
                switch result {
                case .success(let d): cont.resume(returning: d)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }
}
