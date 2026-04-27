//
//  MCPSecret.swift
//  MCP Browser
//
//  Random bearer token gating the local MCP HTTP listener. Generated
//  once on first launch, persisted in UserDefaults, and emitted into
//  the `Authorization: Bearer …` header of every client config we
//  write. Without it, any local process could drive a fully-logged-in
//  browser; with it, only clients that hold the token can.
//

import Foundation

enum MCPSecret {
    nonisolated private static let key = "MCPBrowser.serverToken.v1"

    /// Current token. Generated on first call and persisted thereafter.
    nonisolated static var token: String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        return regenerate()
    }

    /// Mint a fresh token, replacing any existing one. Existing client
    /// configs become invalid and need to be re-registered.
    @discardableResult
    nonisolated static func regenerate() -> String {
        let new = makeToken()
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    /// 32 random bytes, base64url-encoded → 43 chars, URL-safe.
    nonisolated private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if rc != errSecSuccess {
            // Fall back to arc4random — extraordinarily unlikely path.
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...UInt8.max) }
        }
        let b64 = Data(bytes).base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
