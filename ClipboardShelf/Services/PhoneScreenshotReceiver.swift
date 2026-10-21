import Foundation
import Network
import Security
import SystemConfiguration

/// Opt-in local HTTP receiver for an iPhone Shortcuts automation. The random
/// path is a pairing secret; no request is accepted without it.
final class PhoneScreenshotReceiver {
    static let enabledKey = "phoneScreenshotReceivingEnabled"
    static let tokenKey = "phoneScreenshotReceivingToken"
    static let port: UInt16 = 52781
    private static let maximumConcurrentConnections = 8

    enum ImportResult {
        case saved
        case alreadySaved
        case rejected
    }

    private let queue = DispatchQueue(label: "com.cliphoook.phone-screenshot-receiver")
    private let expectedPath: String
    private let port: UInt16
    private let onImage: (Data, @escaping (ImportResult) -> Void) -> Void
    private let onState: (String) -> Void
    private var listener: NWListener?
    private var connections: [UUID: PhoneScreenshotConnection] = [:]

    init(token: String, port: UInt16 = PhoneScreenshotReceiver.port,
         onImage: @escaping (Data, @escaping (ImportResult) -> Void) -> Void,
         onState: @escaping (String) -> Void) {
        expectedPath = "/v1/screenshot/\(token)"
        self.port = port
        self.onImage = onImage
        self.onState = onState
    }

    static func token(in defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: tokenKey), saved.count == 32,
           saved.utf8.allSatisfy({ $0.isASCIIHexDigit }) {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = Array(UUID().uuidString.replacingOccurrences(of: "-", with: "").utf8.prefix(16))
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: tokenKey)
        return token
    }

    static func endpoint(token: String) -> String {
        let localName = (SCDynamicStoreCopyLocalHostName(nil) as String?)
            ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        let encodedName = localName.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            ?? localName
        return "http://\(encodedName).local:\(port)/v1/screenshot/\(token)"
    }

    func start() throws {
        guard listener == nil else { return }
        let port = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: .tcp, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onState("已就绪，等待 iPhone 截图")
            case .failed(let error): self.onState("接收失败：\(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connections.count < Self.maximumConcurrentConnections else {
                connection.cancel()
                return
            }
            let id = UUID()
            let handler = PhoneScreenshotConnection(
                connection: connection, expectedPath: self.expectedPath,
                onImage: self.onImage
            ) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            self.connections[id] = handler
            handler.start(on: self.queue)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }
}

private final class PhoneScreenshotConnection {
    private static let maximumImageBytes = 15 * 1_024 * 1_024
    private let connection: NWConnection
    private let expectedPath: String
    private let onImage: (Data, @escaping (PhoneScreenshotReceiver.ImportResult) -> Void) -> Void
    private let onFinish: () -> Void
    private let parser = PhoneScreenshotHTTPParser(maximumBodyBytes: maximumImageBytes)
    private var queue: DispatchQueue?
    private var checkedPath = false
    private var sentContinue = false
    private var finished = false

    init(connection: NWConnection, expectedPath: String,
         onImage: @escaping (Data, @escaping (PhoneScreenshotReceiver.ImportResult) -> Void) -> Void,
         onFinish: @escaping () -> Void) {
        self.connection = connection
        self.expectedPath = expectedPath
        self.onImage = onImage
        self.onFinish = onFinish
    }

    func start(on queue: DispatchQueue) {
        self.queue = queue
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish()
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if error != nil { self.finish(); return }
            do {
                let request = try self.parser.append(data ?? Data())
                if !self.checkedPath, let line = self.parser.requestLine {
                    self.checkedPath = true
                    guard Self.constantTimeEqual(line.path, self.expectedPath) else {
                        self.respond(403, "forbidden")
                        return
                    }
                }
                if self.parser.expectsContinue && !self.sentContinue && request == nil {
                    self.sentContinue = true
                    self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                                         completion: .contentProcessed { _ in })
                }
                if let request {
                    guard !request.body.isEmpty else { self.respond(400, "empty image"); return }
                    self.onImage(request.body) { [weak self] result in
                        guard let self, let queue = self.queue else { return }
                        queue.async {
                            switch result {
                            case .saved: self.respond(200, "saved")
                            case .alreadySaved: self.respond(200, "already saved")
                            case .rejected: self.respond(415, "invalid image")
                            }
                        }
                    }
                } else if isComplete {
                    self.respond(400, "incomplete request")
                } else {
                    self.receive()
                }
            } catch PhoneScreenshotHTTPParser.ParseError.tooLarge {
                self.respond(413, "image too large")
            } catch PhoneScreenshotHTTPParser.ParseError.lengthRequired {
                self.respond(411, "length required")
            } catch {
                self.respond(400, "invalid request")
            }
        }
    }

    private func respond(_ code: Int, _ message: String) {
        guard !finished else { return }
        let status: String
        switch code {
        case 200: status = "OK"
        case 400: status = "Bad Request"
        case 403: status = "Forbidden"
        case 411: status = "Length Required"
        case 413: status = "Content Too Large"
        default: status = "Unsupported Media Type"
        }
        let body = Data("{\"result\":\"\(message)\"}".utf8)
        var response = Data("HTTP/1.1 \(code) \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onFinish()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (97...102).contains(self)
    }
}
