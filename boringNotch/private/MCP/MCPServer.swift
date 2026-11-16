//
//  MCPServer.swift
//  ZenNotch
//
//  A local MCP server (Streamable HTTP, JSON replies) so AI apps like Claude, Cursor
//  or Claude Code can read and change the user's tasks.
//
//  Safety: off by default; listens on 127.0.0.1 only; every request needs the bearer
//  token from mcp.json (kept private to this user); the Host and Origin headers must
//  be local, which blocks web pages from reaching it (DNS rebinding).
//

import Defaults
import Foundation
import Network
import Security

// MARK: - Config file (port + token), shared with the stdio bridge

enum MCPConfig {
    struct Values: Codable {
        var port: Int
        var token: String
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZenNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mcp.json")
    }

    static func load() -> Values? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Values.self, from: data)
    }

    static func save(_ values: Values) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // The token is a password: only this user may read it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Server

@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()

    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var token: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "site.kiranalex.zennotch.mcp")
    private var observers: [Defaults.Observation] = []

    var port: Int { Defaults[.mcpPort] }
    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    private init() {
        token = MCPConfig.load()?.token ?? MCPConfig.newToken()
        observers.append(Defaults.observe(.mcpEnabled) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        })
        observers.append(Defaults.observe(.mcpPort) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        })
    }

    /// What the running listener was started with, so repeated calls don't restart it.
    private var activeConfig: (port: Int, token: String)?

    /// Starts or stops the server to match Settings.
    func applySettings() {
        guard Defaults[.mcpEnabled] else {
            stop()
            return
        }
        if let active = activeConfig, active.port == port, active.token == token, listener != nil { return }
        stop()
        start()
    }

    func regenerateToken() {
        token = MCPConfig.newToken()
        applySettings()
    }

    private func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port >= 1024 else {
            status = .failed("Port must be between 1024 and 65535.")
            return
        }
        MCPConfig.save(.init(port: port, token: token))
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: never reachable from the network.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        do {
            let listener = try NWListener(using: params)
            let port = self.port
            let token = self.token
            status = .starting
            activeConfig = (port, token)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.status = .running(port: port)
                    case .failed(let error):
                        self.status = .failed(error.localizedDescription.contains("in use")
                            ? "Port \(port) is already in use. Pick another port." : error.localizedDescription)
                        listener.cancel()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { connection in
                MCPConnection(connection, port: port, token: token).start()
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        activeConfig = nil
        status = .off
    }
}

// MARK: - One HTTP request

/// Reads one request, answers it, closes. (The replies are small and one-shot, so no
/// keep-alive or streaming is needed.)
final class MCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let port: Int
    private let token: String
    private var buffer = Data()
    private var timeout: DispatchWorkItem?
    private let queue = DispatchQueue(label: "site.kiranalex.zennotch.mcp.conn")

    private static let maxRequest = 2_000_000

    init(_ connection: NWConnection, port: Int, token: String) {
        self.connection = connection
        self.port = port
        self.token = token
    }

    func start() {
        connection.start(queue: queue)
        // A client that connects and goes quiet shouldn't hold a socket forever.
        let work = DispatchWorkItem { [weak self] in self?.connection.cancel() }
        timeout = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequest { return respond(413, "Request too large.") }
            switch parse() {
            case .incomplete:
                if error != nil || isComplete { connection.cancel() } else { receive() }
            case .invalid:
                respond(400, "Bad request.")
            case .request(let request):
                timeout?.cancel()
                route(request)
            }
        }
    }

    // MARK: Parsing

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private enum Parsed { case incomplete, invalid, request(Request) }

    private func parse() -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else { return .incomplete }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= Self.maxRequest else { return .invalid }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        return .request(Request(method: String(requestLine[0]), path: String(requestLine[1]),
                                headers: headers, body: Data(body)))
    }

    // MARK: Routing

    private func route(_ r: Request) {
        // Only local pages may talk to us: blocks DNS-rebinding from a web page.
        let allowedHosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "127.0.0.1", "localhost"]
        guard allowedHosts.contains((r.headers["host"] ?? "").lowercased()) else { return respond(403, "Forbidden host.") }
        if let origin = r.headers["origin"], !origin.isEmpty,
           !(origin.hasPrefix("http://127.0.0.1") || origin.hasPrefix("http://localhost")) {
            return respond(403, "Forbidden origin.")
        }
        guard Self.constantTimeEqual(r.headers["authorization"] ?? "", "Bearer \(token)") else {
            return respond(401, "Missing or wrong token.", extra: ["WWW-Authenticate": "Bearer"])
        }
        let path = r.path.split(separator: "?").first.map(String.init) ?? r.path
        guard path == "/mcp" || path == "/" else { return respond(404, "Not found.") }
        guard r.method == "POST" else {
            return respond(405, "Use POST.", extra: ["Allow": "POST"])
        }

        Task {
            let (status, body) = await MCPConnection.process(r.body)
            self.respond(status, body: body)
        }
    }

    /// One HTTP body in (one JSON-RPC message or a batch), the reply out.
    private static func process(_ body: Data) async -> (Int, Data?) {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return (400, errorBody(code: -32700, message: "Parse error"))
        }
        let messages: [[String: Any]]
        let isBatch: Bool
        if let one = object as? [String: Any] { messages = [one]; isBatch = false }
        else if let many = object as? [[String: Any]], !many.isEmpty { messages = many; isBatch = true }
        else { return (400, errorBody(code: -32600, message: "Invalid request")) }

        var replies: [[String: Any]] = []
        for message in messages {
            if let reply = await MCPProtocol.handle(message) { replies.append(reply) }
        }
        if replies.isEmpty { return (202, nil) }
        let payload: Any = isBatch ? replies : replies[0]
        return (200, try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]))
    }

    private static func errorBody(code: Int, message: String) -> Data {
        let o: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    // MARK: Responding

    private func respond(_ status: Int, _ message: String, extra: [String: String] = [:]) {
        respond(status, body: Data(message.utf8), contentType: "text/plain; charset=utf-8", extra: extra)
    }

    private func respond(_ status: Int, body: Data?, contentType: String = "application/json",
                         extra: [String: String] = [:]) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if body != nil { head += "Content-Type: \(contentType)\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        connection.send(content: out, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}

// MARK: - stdio bridge

/// `ZenNotch --mcp-stdio`: lets clients that launch a command (Claude Desktop, Cursor)
/// reach the running app. Reads JSON-RPC lines on stdin, forwards each to the local
/// server, and prints the replies. The app itself does the work; this only relays.
enum MCPStdioBridge {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp-stdio") else { return }
        run()
        exit(0)
    }

    private static func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let id = (object as? [String: Any])?["id"]
            let isRequest = id != nil && !(id is NSNull) && (object as? [String: Any])?["method"] != nil

            switch forward(data) {
            case .reply(let body):
                if !body.isEmpty, let text = String(data: body, encoding: .utf8) { emit(text) }
            case .failure(let message):
                // Only requests expect an answer; tell the client why it won't get one.
                if isRequest, let id {
                    let err: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
                    if let d = try? JSONSerialization.data(withJSONObject: err), let s = String(data: d, encoding: .utf8) { emit(s) }
                }
            }
        }
    }

    private enum Outcome { case reply(Data), failure(String) }

    private static func forward(_ body: Data) -> Outcome {
        guard let config = MCPConfig.load() else {
            return .failure("ZenNotch's MCP server hasn't been turned on. Open ZenNotch > Settings > General > AI apps (MCP).")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/mcp")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let done = DispatchSemaphore(value: 0)
        var outcome: Outcome = .failure("No answer from ZenNotch.")
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                outcome = .failure("Can't reach ZenNotch (\(error.localizedDescription)). Is the app running with the MCP server turned on?")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: outcome = .reply(data ?? Data())
            case 202: outcome = .reply(Data())
            case 401: outcome = .failure("ZenNotch rejected the token. Restart your AI app so it picks up the new one.")
            default: outcome = .failure("ZenNotch answered with HTTP \(status).")
            }
        }.resume()
        done.wait()
        return outcome
    }

    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
