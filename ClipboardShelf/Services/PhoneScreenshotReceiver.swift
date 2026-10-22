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
    private let expectedUploadPath: String
    private let expectedSetupPath: String
    private let expectedShortcutPath: String
    private let endpointAddress: String
    private let shortcutData: Data?
    private let port: UInt16
    private let onImage: (Data, @escaping (ImportResult) -> Void) -> Void
    private let onState: (String) -> Void
    private var listener: NWListener?
    private var connections: [UUID: PhoneScreenshotConnection] = [:]

    init(token: String, port: UInt16 = PhoneScreenshotReceiver.port,
         shortcutData: Data? = Bundle.main.url(forResource: "ClipHoook-iPhone-Screenshot",
                                               withExtension: "shortcut")
            .flatMap { try? Data(contentsOf: $0) },
         onImage: @escaping (Data, @escaping (ImportResult) -> Void) -> Void,
         onState: @escaping (String) -> Void) {
        expectedUploadPath = "/v1/screenshot/\(token)"
        expectedSetupPath = "/v1/setup/\(token)"
        expectedShortcutPath = "/v1/shortcut/\(token)"
        endpointAddress = Self.endpoint(token: token, port: port)
        self.shortcutData = shortcutData
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

    static func endpoint(token: String, port: UInt16 = PhoneScreenshotReceiver.port) -> String {
        let localName = (SCDynamicStoreCopyLocalHostName(nil) as String?)
            ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        let encodedName = localName.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            ?? localName
        return "http://\(encodedName).local:\(port)/v1/screenshot/\(token)"
    }

    static func setupAddress(token: String, port: UInt16 = PhoneScreenshotReceiver.port) -> String {
        endpoint(token: token, port: port)
            .replacingOccurrences(of: "/v1/screenshot/", with: "/v1/setup/")
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
                connection: connection,
                uploadPath: self.expectedUploadPath,
                setupPath: self.expectedSetupPath,
                shortcutPath: self.expectedShortcutPath,
                endpointAddress: self.endpointAddress,
                shortcutData: self.shortcutData,
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
    private let uploadPath: String
    private let setupPath: String
    private let shortcutPath: String
    private let endpointAddress: String
    private let shortcutData: Data?
    private let onImage: (Data, @escaping (PhoneScreenshotReceiver.ImportResult) -> Void) -> Void
    private let onFinish: () -> Void
    private let parser = PhoneScreenshotHTTPParser(maximumBodyBytes: maximumImageBytes)
    private var queue: DispatchQueue?
    private var checkedPath = false
    private var sentContinue = false
    private var finished = false

    init(connection: NWConnection, uploadPath: String, setupPath: String,
         shortcutPath: String, endpointAddress: String, shortcutData: Data?,
         onImage: @escaping (Data, @escaping (PhoneScreenshotReceiver.ImportResult) -> Void) -> Void,
         onFinish: @escaping () -> Void) {
        self.connection = connection
        self.uploadPath = uploadPath
        self.setupPath = setupPath
        self.shortcutPath = shortcutPath
        self.endpointAddress = endpointAddress
        self.shortcutData = shortcutData
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
                    let allowed = (line.method == "POST" &&
                                   Self.constantTimeEqual(line.path, self.uploadPath)) ||
                                  (line.method == "GET" &&
                                   (Self.constantTimeEqual(line.path, self.setupPath) ||
                                    Self.constantTimeEqual(line.path, self.shortcutPath)))
                    guard allowed else {
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
                    if request.method == "GET" {
                        if Self.constantTimeEqual(request.path, self.setupPath) {
                            self.respondData(200, contentType: "text/html; charset=utf-8",
                                             body: Data(self.setupPage().utf8),
                                             extraHeaders: "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'\r\n")
                        } else if let shortcutData = self.shortcutData {
                            self.respondData(200, contentType: "application/x-apple-shortcut",
                                             body: shortcutData,
                                             extraHeaders: "Content-Disposition: attachment; filename=\"ClipHoook-iPhone-Screenshot.shortcut\"\r\n")
                        } else {
                            self.respond(503, "shortcut unavailable")
                        }
                        return
                    }
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
        case 503: status = "Service Unavailable"
        default: status = "Unsupported Media Type"
        }
        let body = Data("{\"result\":\"\(message)\"}".utf8)
        respondData(code, status: status, contentType: "application/json", body: body)
    }

    private func respondData(_ code: Int, status: String = "OK", contentType: String,
                             body: Data, extraHeaders: String = "") {
        guard !finished else { return }
        var response = Data("HTTP/1.1 \(code) \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\(extraHeaders)Connection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func setupPage() -> String {
        let address = endpointAddress.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>设置 iPhone 截图直达 ClipHoook</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f4f6fa;color:#172033;margin:0;padding:24px}main{max-width:520px;margin:auto}h1{font-size:25px}p,li{line-height:1.55}section{background:white;border-radius:18px;padding:20px;margin:16px 0;box-shadow:0 4px 24px #16294412}a.button,button{display:block;box-sizing:border-box;width:100%;border:0;border-radius:12px;background:#087cff;color:white;font-size:17px;font-weight:600;padding:15px;text-align:center;text-decoration:none}button{margin-top:10px}input{box-sizing:border-box;width:100%;font-size:13px;padding:12px;border:1px solid #bbc6d5;border-radius:10px}small{color:#627086}ol{padding-left:23px}</style></head><body><main>
        <h1>iPhone 截图直达 ClipHoook</h1><p>这台 Mac 已开启接收。请让 iPhone 和 Mac 保持在同一可信局域网。</p>
        <section><strong>1. 下载快捷指令模板</strong><p>下载后在“文件”中点开，添加到“快捷指令”。模板不含任何人的接收地址。</p><a class="button" href="\(shortcutPath)">下载快捷指令模板</a></section>
        <section><strong>2. 填入这台 Mac 的地址</strong><p>编辑刚添加的快捷指令，把“URL”操作里的示例地址替换成以下完整地址。</p><input id="address" readonly value="\(address)"><button onclick="copyAddress()">复制接收地址</button><small id="copyHint">如果复制按钮无效，可长按上方地址并复制。请勿把地址分享给他人。</small></section>
        <section><strong>3. 开启截屏自动化</strong><ol><li>打开“快捷指令 → 自动化”，新建“截屏 → 已保存截屏时”，选择“照片”。</li><li>选择“运行快捷指令”，指向刚添加的 ClipHoook 模板，并设为自动运行。</li><li>保存一张新截图，检查 Mac 上是否出现“iPhone 截图”卡片。</li></ol></section>
        <p><small>离开这台 Mac 所在的 Wi-Fi 时，上传可能超时。可在自动化前面按 Wi-Fi 名称添加“如果”判断，只在指定网络运行。Mac 休眠或离线时也无法接收。</small></p>
        </main><script>function copyAddress(){let field=document.getElementById('address');field.select();field.setSelectionRange(0,field.value.length);let ok=document.execCommand('copy');document.getElementById('copyHint').textContent=ok?'已复制地址，请在快捷指令的 URL 操作中粘贴。':'请长按地址并复制。';}</script></body></html>
        """
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
