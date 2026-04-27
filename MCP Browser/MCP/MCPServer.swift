//
//  MCPServer.swift
//  MCP Browser
//
//  A minimal HTTP server that speaks MCP's JSON-RPC over POST /mcp.
//  Uses Network.framework's NWListener so it plays nicely with the
//  App Sandbox (server entitlement is enough — no BSD sockets).
//
//  Transport semantics follow the MCP "Streamable HTTP" spec but we
//  only implement the non-streaming variant: client POSTs a single
//  JSON-RPC request, server responds with `application/json`. Good
//  enough for tool calls; SSE can come later if we add notifications.
//

import Foundation
import Network

/// Entire server runs off the main actor — it's driven by Network.framework
/// callbacks on its own dispatch queue. Tool handlers hop to @MainActor
/// explicitly when they need to touch WKWebView.
nonisolated final class MCPServer: @unchecked Sendable {
    enum LifecycleState: Sendable {
        case starting
        case ready
        case failed(String)
        case stopped
    }

    private let listener: NWListener
    private let port: UInt16
    private let tools: MCPToolRegistry
    private let queue = DispatchQueue(label: "mcp.server")
    private let onStateChange: @Sendable (LifecycleState) -> Void
    private let tokenProvider: @Sendable () -> String
    private let allowedHosts: Set<String>
    private let allowedOrigins: Set<String>

    init(
        port: UInt16,
        token: @escaping @Sendable () -> String,
        host: @escaping @Sendable @MainActor () -> (any MCPHost)?,
        onStateChange: @escaping @Sendable (LifecycleState) -> Void = { _ in }
    ) throws {
        self.port = port
        self.tokenProvider = token
        self.tools = MCPToolRegistry(host: host)
        self.onStateChange = onStateChange
        self.allowedHosts = [
            "127.0.0.1:\(port)",
            "localhost:\(port)"
        ]
        self.allowedOrigins = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)",
            "null"
        ]

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback-only binding. Setting requiredLocalEndpoint AND passing
        // a port to NWListener(using:on:) conflicts, so we put the full
        // address in the parameters and omit the port argument.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        self.listener = try NWListener(using: params)
    }

    func start() throws {
        onStateChange(.starting)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.onStateChange(.ready)
                NSLog("MCP server listening on http://127.0.0.1:\(self.port)/mcp")
            case .failed(let err):
                self.onStateChange(.failed(err.localizedDescription))
                NSLog("MCP server failed: \(err)")
            case .cancelled:
                self.onStateChange(.stopped)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readRequest(on: conn, buffer: Data())
            case .failed, .cancelled:
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// Reads from the connection until we have a complete HTTP request
    /// (headers terminator + full Content-Length body), then dispatches.
    private func readRequest(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("MCP read error: \(error)")
                conn.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }

            // Split headers/body on CRLFCRLF.
            guard let split = buf.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
                if isComplete { conn.cancel() } else { self.readRequest(on: conn, buffer: buf) }
                return
            }
            let headerData = buf.subdata(in: 0..<split.lowerBound)
            let afterHeaders = buf.subdata(in: split.upperBound..<buf.endIndex)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                self.write(status: 400, body: "bad request", on: conn)
                return
            }

            let request = HTTPRequest(parsingHeaders: headerString)
            let contentLength = request.headers["content-length"].flatMap(Int.init) ?? 0
            if afterHeaders.count < contentLength {
                // Need more body bytes.
                self.readRequest(on: conn, buffer: buf)
                return
            }
            let body = afterHeaders.prefix(contentLength)
            self.dispatch(request: request, body: Data(body), on: conn)
        }
    }

    private func dispatch(request: HTTPRequest, body: Data, on conn: NWConnection) {
        // Health probe for humans hitting the URL — unauthenticated by
        // design so a quick `curl http://127.0.0.1:8833/` still works.
        if request.method == "GET" && request.path == "/" {
            write(status: 200, body: "MCP Browser is running. POST JSON-RPC to /mcp\n", on: conn)
            return
        }
        guard request.method == "POST", request.path == "/mcp" else {
            write(status: 404, body: "not found\n", on: conn)
            return
        }

        // DNS-rebinding defence: even though we're bound to loopback, a
        // malicious page could resolve attacker.com → 127.0.0.1 and
        // POST from JS. Require Host (and Origin, when present) to be
        // an explicit loopback name.
        let hostHeader = (request.headers["host"] ?? "").lowercased()
        if !allowedHosts.contains(hostHeader) {
            write(status: 403, body: "forbidden host\n", on: conn)
            return
        }
        if let origin = request.headers["origin"]?.lowercased(),
           !origin.isEmpty,
           !allowedOrigins.contains(origin) {
            write(status: 403, body: "forbidden origin\n", on: conn)
            return
        }

        // Bearer-token auth. Constant-time-ish compare (matches lengths
        // first, then equates byte-by-byte) — the token is opaque so
        // timing attacks aren't really in scope, but cheap to do right.
        guard let presented = bearerToken(in: request.headers["authorization"]),
              tokensMatch(presented, tokenProvider()) else {
            var head = "HTTP/1.1 401 Unauthorized\r\n"
            head += "WWW-Authenticate: Bearer\r\n"
            head += "Content-Type: text/plain; charset=utf-8\r\n"
            head += "Content-Length: 13\r\n"
            head += "Connection: close\r\n\r\n"
            head += "unauthorized\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        Task.detached { [tools] in
            let responseJSON = await tools.handle(jsonRPCBody: body)
            self.write(status: 200, contentType: "application/json", body: responseJSON, on: conn)
        }
    }

    private func bearerToken(in header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let prefix = "bearer "
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func tokensMatch(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= (ab[i] ^ bb[i]) }
        return diff == 0
    }

    // MARK: - HTTP response helpers

    private func write(status: Int, contentType: String = "text/plain; charset=utf-8", body: String, on conn: NWConnection) {
        write(status: status, contentType: contentType, body: Data(body.utf8), on: conn)
    }

    private func write(status: Int, contentType: String, body: Data, on conn: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default:  reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - HTTP request parsing

private struct HTTPRequest {
    var method: String = ""
    var path: String = ""
    var headers: [String: String] = [:]

    init(parsingHeaders raw: String) {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return }
        let requestLine = first.split(separator: " ")
        if requestLine.count >= 2 {
            method = String(requestLine[0])
            path = String(requestLine[1])
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(key)] = value
        }
    }
}
