//
//  BrowserTab+Cookies.swift
//  MCP Browser
//
//  Cookie + website-data tools: get_cookies, set_cookie, clear_session.
//  All operations target the shared default WKWebsiteDataStore so they
//  affect every tab in this process equally.
//

import Foundation
import WebKit

extension BrowserTab {

    /// All cookies currently in the shared store. With `domain`, filters
    /// to entries whose domain hierarchy overlaps the argument.
    func getCookies(domain: String?) async -> [HTTPCookie] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        guard let domain, !domain.isEmpty else { return all }
        return all.filter { $0.domain.hasSuffix(domain) || domain.hasSuffix($0.domain) }
    }

    /// Insert or update a cookie.
    func setCookie(_ cookie: HTTPCookie) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) { cont.resume() }
        }
    }

    /// Wipe cookies + storage for all origins. Destructive — used by
    /// the `clear_session` MCP tool.
    func clearSession() async {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
