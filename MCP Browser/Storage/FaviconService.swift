//
//  FaviconService.swift
//  MCP Browser
//
//  Tiny per-host favicon cache. Looks first in memory, then on disk
//  (Application Support / MCP Browser / favicons), then falls back to
//  Google's favicon service. Returns nil while a fetch is in flight —
//  the @Observable cache mutation re-renders the calling view when
//  the icon arrives.
//

import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class FaviconService {

    /// Reading from this dictionary in a SwiftUI view body registers
    /// the observation, so the view re-renders when an async fetch
    /// populates a host.
    private(set) var cache: [String: NSImage] = [:]

    /// LRU cap on the in-memory cache. Disk copy is kept, so evicted
    /// hosts re-hydrate from disk on the next lookup without a network
    /// round-trip.
    @ObservationIgnored
    private static let memoryCap = 1000

    /// Hosts in least-recently-used → most-recently-used order. Updated
    /// on every read so eviction targets cold entries.
    @ObservationIgnored
    private var lru: [String] = []

    @ObservationIgnored
    private var pending: Set<String> = []

    /// Hosts whose fetch already returned nothing. Without this, every
    /// re-render of a chip whose favicon failed kicks off a fresh fetch
    /// — and because `cache` is observed, *any* successful favicon
    /// load anywhere invalidates every chip, fueling a feedback loop
    /// that constantly reflows the bar.
    @ObservationIgnored
    private var failed: Set<String> = []

    @ObservationIgnored
    private static let directory: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true)) ?? fm.temporaryDirectory
        let dir = support
            .appendingPathComponent("MCP Browser", isDirectory: true)
            .appendingPathComponent("favicons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Synchronous lookup for the favicon associated with `urlString`.
    /// Returns nil if we don't have it yet; kicks off an async fetch
    /// in that case so a later body pass picks it up.
    func icon(for urlString: String) -> NSImage? {
        guard let host = host(from: urlString) else { return nil }
        if let cached = cache[host] {
            touch(host)
            return cached
        }
        if failed.contains(host) { return nil }
        if pending.insert(host).inserted {
            Task { await fetch(host: host) }
        }
        return nil
    }

    // MARK: - Internals

    private func host(from urlString: String) -> String? {
        URL(string: urlString)?.host?.lowercased()
    }

    private func fetch(host: String) async {
        defer { pending.remove(host) }

        if let onDisk = loadFromDisk(host: host) {
            store(image: onDisk, for: host)
            return
        }

        // Google's S2 favicon endpoint — works for any host without
        // requiring us to parse the page's <link rel="icon"> first.
        guard let endpoint = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") else {
            failed.insert(host)
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let image = NSImage(data: data) else {
            failed.insert(host)
            return
        }

        store(image: image, for: host)
        try? data.write(to: path(for: host))
    }

    private func store(image: NSImage, for host: String) {
        cache[host] = image
        touch(host)
    }

    private func touch(_ host: String) {
        if let idx = lru.firstIndex(of: host) {
            lru.remove(at: idx)
        }
        lru.append(host)
        while lru.count > Self.memoryCap {
            let evict = lru.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }

    private func loadFromDisk(host: String) -> NSImage? {
        guard let data = try? Data(contentsOf: path(for: host)) else { return nil }
        return NSImage(data: data)
    }

    private func path(for host: String) -> URL {
        // Sanitize host for use as a filename. Hosts shouldn't contain
        // path separators in practice but defensive escaping is cheap.
        let safe = host.replacingOccurrences(of: "/", with: "-")
        return Self.directory.appendingPathComponent("\(safe).png")
    }
}
