//
//  SearchEngine.swift
//  MCP Browser
//
//  User-selectable search engine for URL-bar queries that don't look
//  like URLs. Reads from UserDefaults so settings changes take effect
//  without touching the BrowserTab.
//

import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckduckgo
    case bing
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .google:     return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing:       return "Bing"
        case .custom:     return "Custom"
        }
    }

    static let storageKey = "searchEngine"
    static let customTemplateKey = "searchCustomTemplate"

    /// Currently-selected engine, falling back to Google.
    static var current: SearchEngine {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return SearchEngine(rawValue: raw) ?? .google
    }

    /// Build a search URL for `query`. Custom templates use `{q}` as the
    /// placeholder, e.g. `https://my.example/?q={q}`.
    func searchURL(for query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let template: String
        switch self {
        case .google:     template = "https://www.google.com/search?q={q}"
        case .duckduckgo: template = "https://duckduckgo.com/?q={q}"
        case .bing:       template = "https://www.bing.com/search?q={q}"
        case .custom:
            let stored = UserDefaults.standard.string(forKey: Self.customTemplateKey) ?? ""
            template = stored.contains("{q}")
                ? stored
                : "https://www.google.com/search?q={q}"
        }
        let urlStr = template.replacingOccurrences(of: "{q}", with: encoded)
        return URL(string: urlStr) ?? URL(string: "https://www.google.com")!
    }
}
