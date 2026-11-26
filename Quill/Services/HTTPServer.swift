import Foundation
import Network
import Security

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    /// Temporäre Datei mit dem Request-Body (nur bei POST/PUT mit Content-Length).
    let bodyFile: URL?
}

enum HTTPBody {
    case data(Data)
    case file(URL)
}

struct HTTPResponse {
    var status = 200
    var contentType = "text/plain; charset=utf-8"
    var headers: [String: String] = [:]
    var body: HTTPBody = .data(Data())

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: .data(Data(text.utf8)))
    }

    static func html(_ html: String) -> HTTPResponse {
        HTTPResponse(contentType: "text/html; charset=utf-8", body: .data(Data(html.utf8)))
    }

    static func file(_ url: URL, contentType: String = "application/octet-stream", downloadName: String? = nil) -> HTTPResponse {
        var response = HTTPResponse(contentType: contentType, body: .file(url))
        if let downloadName {
            let encoded = downloadName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
            response.headers["Content-Disposition"] = "attachment; filename*=UTF-8''\(encoded)"
        }
        return response
    }
}

/// Kleiner HTTP/1.1-Server auf Basis von Network.framework, optional mit TLS.
/// Reicht für die App-Installation (Manifest + IPA) und die WLAN-Dateiübertragung.
final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    let port: UInt16
    private let identity: SecIdentity?
    private let loopbackOnly: Bool
    private let handler: Handler
    private let queue = DispatchQueue(label: "quill.http-server")
    private var listener: NWListener?
    /// Meldet Zustandswechsel des Servers (z. B. „ready“, „failed: …“), für Protokolle.
    var onState: (@Sendable (String) -> Void)?
    /// Diagnose auf Verbindungsebene: auch Verbindungen, aus denen keine gültige Anfrage wird.
    var onTrace: (@Sendable (String) -> Void)?

    init(port: UInt16, identity: SecIdentity? = nil, loopbackOnly: Bool = false, handler: @escaping Handler) {
        self.port = port
        self.identity = identity
        self.loopbackOnly = loopbackOnly
        self.handler = handler
    }

    func start() throws {
        let parameters: NWParameters
        if let identity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = NWParameters.tcp
        }
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly {
            parameters.requiredInterfaceType = .loopback
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AppError("Ungültiger Port \(Int(port)).")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        let handler = self.handler
        let queue = self.queue
        let trace = self.onTrace
        listener.newConnectionHandler = { connection in
            trace?("Connection from \(connection.endpoint)")
            HTTPConnection(connection: connection, queue: queue, handler: handler, trace: trace).start()
        }
        let onState = self.onState
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState?("ready")
            case .failed(let error): onState?("failed: \(error)")
            case .waiting(let error): onState?("waiting: \(error)")
            case .cancelled: onState?("cancelled")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Eine Verbindung = eine Anfrage (Connection: close).
private final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private let trace: (@Sendable (String) -> Void)?

    private var buffer = Data()
    private var bodyFile: URL?
    private var bodyHandle: FileHandle?
    private var remaining = 0
    private var parsed: (method: String, path: String, query: [String: String], headers: [String: String])?

    private static let maxHeaderSize = 64 * 1024
    private static let chunkSize = 256 * 1024

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler,
         trace: (@Sendable (String) -> Void)? = nil) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.trace = trace
    }

    func start() {
        connection.start(queue: queue)
        receiveHeader()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if let range = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                let rest = self.buffer.subdata(in: range.upperBound..<self.buffer.endIndex)
                self.buffer = Data()
                self.handleHead(head, rest: rest)
            } else if error != nil || isComplete || self.buffer.count > Self.maxHeaderSize {
                // 0x16 am Anfang wäre ein TLS-Handshake, also ein HTTPS-Versuch auf dem HTTP-Port.
                let start = self.buffer.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                self.trace?("Connection closed without a valid request · \(self.buffer.count) bytes [\(start)] · \(error.map { "\($0)" } ?? "closed by peer")")
                self.close()
            } else {
                self.receiveHeader()
            }
        }
    }

    private func handleHead(_ head: Data, rest: Data) {
        guard let text = String(data: head, encoding: .utf8) else { return close() }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return close() }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let components = URLComponents(string: "http://localhost" + String(requestLine[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        parsed = (String(requestLine[0]).uppercased(), components?.path ?? "/", query, headers)

        if headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            buffer = rest
            return consumeChunked()
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard length > 0 else { return respond() }

        let file = Paths.temporary.appendingPathComponent("upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else { return close() }
        bodyFile = file
        bodyHandle = handle
        remaining = length
        consumeBody(rest)
    }

    /// Body mit „Transfer-Encoding: chunked“ (kleine Bodys, z. B. die Antwort eines iOS-Profils).
    private func consumeChunked() {
        if let body = Self.decodeChunked(buffer) {
            let file = Paths.temporary.appendingPathComponent("upload-\(UUID().uuidString)")
            guard (try? body.write(to: file)) != nil else { return close() }
            bodyFile = file
            buffer = Data()
            return respond()
        }
        guard buffer.count < 8 * 1024 * 1024 else { return close() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.consumeChunked()
            } else if error != nil || isComplete {
                self.close()
            } else {
                self.consumeChunked()
            }
        }
    }

    /// Liefert den zusammengesetzten Body, sobald der Abschluss-Chunk (Länge 0) da ist; sonst nil.
    private static func decodeChunked(_ data: Data) -> Data? {
        var body = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while let lineEnd = data.range(of: crlf, in: index..<data.endIndex) {
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            if size == 0 { return body }
            let start = lineEnd.upperBound
            guard data.endIndex - start >= size + 2 else { return nil }
            body.append(data[start..<start + size])
            index = start + size + 2
        }
        return nil
    }

    private func consumeBody(_ data: Data) {
        if !data.isEmpty {
            let slice = data.prefix(remaining)
            try? bodyHandle?.write(contentsOf: slice)
            remaining -= slice.count
        }
        if remaining <= 0 {
            try? bodyHandle?.close()
            bodyHandle = nil
            return respond()
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.consumeBody(data)
            } else if error != nil || isComplete {
                self.close()
            } else {
                self.consumeBody(Data())
            }
        }
    }

    private func respond() {
        guard let parsed else { return close() }
        let request = HTTPRequest(method: parsed.method, path: parsed.path, query: parsed.query,
                                  headers: parsed.headers, bodyFile: bodyFile)
        let response = handler(request)

        let length: Int64
        switch response.body {
        case .data(let data): length = Int64(data.count)
        case .file(let url): length = Paths.size(of: url)
        }

        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Connection: close\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        let headOnly = parsed.method == "HEAD"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error != nil || headOnly { return self.close() }
            switch response.body {
            case .data(let data):
                self.connection.send(content: data, completion: .contentProcessed { _ in self.close() })
            case .file(let url):
                guard let handle = try? FileHandle(forReadingFrom: url) else { return self.close() }
                self.sendChunk(from: handle)
            }
        })
    }

    private func sendChunk(from handle: FileHandle) {
        let chunk = try? handle.read(upToCount: Self.chunkSize)
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            return close()
        }
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                self.close()
            } else {
                self.sendChunk(from: handle)
            }
        })
    }

    private func close() {
        try? bodyHandle?.close()
        bodyHandle = nil
        if let bodyFile {
            try? FileManager.default.removeItem(at: bodyFile)
            self.bodyFile = nil
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in self.connection.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 301: return "Moved Permanently"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }
}

enum LocalNetwork {
    /// IPv4-Adresse der WLAN-Schnittstelle (en0), falls verbunden.
    static var wifiAddress: String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var address: String?
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }
}
