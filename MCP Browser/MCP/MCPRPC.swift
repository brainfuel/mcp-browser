//
//  MCPRPC.swift
//  MCP Browser
//
//  Small JSON-RPC value types shared by the registry and its
//  extensions. Both are nonisolated because they're used from the
//  off-main networking queue that drives the HTTP server.
//

import Foundation

/// JSON-RPC error wrapper. Standard codes map to:
///
///   * `-32700` parse error
///   * `-32600` invalid request
///   * `-32601` method not found
///   * `-32602` invalid params
///   * `-32603` internal error
///   * `-32000` server-defined errors (e.g. "no active browser")
nonisolated struct RPCError: Error {
    let code: Int
    let message: String
}

/// Strongly-typed wrapper for the variable-typed JSON-RPC `id` field.
/// JSON-RPC permits string, number, or null; we round-trip whichever
/// the client sent.
nonisolated enum RPCID {
    case null
    case number(Int)
    case string(String)

    init(any: Any?) {
        if let n = any as? Int { self = .number(n) }
        else if let s = any as? String { self = .string(s) }
        else { self = .null }
    }

    var jsonValue: Any {
        switch self {
        case .null:           return NSNull()
        case .number(let n):  return n
        case .string(let s):  return s
        }
    }
}
