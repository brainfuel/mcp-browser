//
//  SandboxStatus.swift
//  MCP Browser
//
//  One-shot probe of the running process's `com.apple.security.app-sandbox`
//  entitlement. Lets the app branch between the direct-FS registrar
//  (open-source / direct-download build) and the security-scoped
//  registrar (Mac App Store build) without recompiling.
//

import Foundation

enum SandboxStatus {
    /// `true` when the running build was code-signed with the App
    /// Sandbox entitlement enabled.
    static let isSandboxed: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.app-sandbox" as CFString,
            nil
        )
        return (value as? Bool) ?? false
    }()
}
