//
//  DownloadStore.swift
//  MCP Browser
//
//  Tracks user-initiated downloads (links the page can't display
//  inline, "Save Link As", etc). Owns the WKDownloadDelegate so per-
//  download progress and lifecycle flow into the UI list.
//

import Foundation
import Observation
import AppKit
import WebKit

@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    var filename: String
    var sourceURL: URL?
    var destination: URL?
    var fractionCompleted: Double = 0
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var state: State = .running
    let startedAt: Date = .now

    @ObservationIgnored
    fileprivate weak var download: WKDownload?

    @ObservationIgnored
    fileprivate var progressObservation: NSKeyValueObservation?

    init(filename: String, sourceURL: URL?) {
        self.filename = filename
        self.sourceURL = sourceURL
    }
}

@MainActor
@Observable
final class DownloadStore: NSObject {
    /// Newest first.
    private(set) var items: [DownloadItem] = []

    @ObservationIgnored
    private var byDownload: [ObjectIdentifier: DownloadItem] = [:]

    /// Wire a freshly-vended `WKDownload` into the list. Called from
    /// `BrowserTab` once WebKit hands one back via `didBecomeDownload`.
    func attach(_ download: WKDownload, sourceURL: URL?, suggestedFilename: String?) {
        let item = DownloadItem(
            filename: suggestedFilename ?? sourceURL?.lastPathComponent.nonEmpty ?? "download",
            sourceURL: sourceURL
        )
        item.download = download
        items.insert(item, at: 0)
        byDownload[ObjectIdentifier(download)] = item
        download.delegate = self

        // WKDownload exposes an NSProgress; observe it for the UI bar.
        item.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self, weak item] progress, _ in
            let fraction = progress.fractionCompleted
            let total = progress.totalUnitCount
            let completed = progress.completedUnitCount
            Task { @MainActor in
                guard let item else { return }
                item.fractionCompleted = fraction
                item.totalBytes = total
                item.receivedBytes = completed
                _ = self  // retain through closure
            }
        }
    }

    /// Record a file the app already wrote to disk (e.g. screenshots,
    /// PDF exports). Adds an entry in the `.finished` state so it shows
    /// up in the downloads popover alongside WebKit-vended downloads.
    func record(finishedFileAt url: URL, sourceURL: URL? = nil) {
        let item = DownloadItem(filename: url.lastPathComponent, sourceURL: sourceURL)
        item.destination = url
        item.fractionCompleted = 1
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            item.totalBytes = Int64(size)
            item.receivedBytes = Int64(size)
        }
        item.state = .finished
        items.insert(item, at: 0)
    }

    func cancel(id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              case .running = item.state else { return }
        item.download?.cancel { _ in }
        item.state = .cancelled
        item.progressObservation = nil
    }

    func remove(id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            item.progressObservation = nil
            if let dl = item.download { byDownload.removeValue(forKey: ObjectIdentifier(dl)) }
            if case .running = item.state { item.download?.cancel { _ in } }
        }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.state {
            case .finished, .failed, .cancelled: return true
            case .running: return false
            }
        }
    }

    func revealInFinder(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFile(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.open(url)
    }

    var hasActiveDownloads: Bool {
        items.contains { if case .running = $0.state { return true } else { return false } }
    }
}

// MARK: - WKDownloadDelegate

extension DownloadStore: WKDownloadDelegate {

    /// Pick a destination in `~/Downloads`, deduping the filename if
    /// something with the same name already exists.
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let item = byDownload[ObjectIdentifier(download)]
        let downloadsDir: URL
        do {
            downloadsDir = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        } catch {
            item?.state = .failed("Couldn't open Downloads folder")
            completionHandler(nil)
            return
        }
        let preferred = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let dest = BrowserTab.uniqueDestination(in: downloadsDir, preferred: preferred)
        item?.filename = dest.lastPathComponent
        item?.destination = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let item = byDownload[ObjectIdentifier(download)] {
            item.fractionCompleted = 1
            item.state = .finished
            item.progressObservation = nil
        }
        byDownload.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload,
                  didFailWithError error: Error,
                  resumeData: Data?) {
        if let item = byDownload[ObjectIdentifier(download)] {
            item.state = .failed(error.localizedDescription)
            item.progressObservation = nil
        }
        byDownload.removeValue(forKey: ObjectIdentifier(download))
    }
}
