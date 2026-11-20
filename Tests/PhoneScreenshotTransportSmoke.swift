import Foundation

@main
struct PhoneScreenshotTransportSmoke {
    static func main() throws {
        let port = UInt16.random(in: 40_000...60_000)
        let payload = Data([0x89, 0x50, 0x4e, 0x47])
        let shortcut = Data("signed-shortcut-fixture".utf8)
        let lock = NSLock()
        var received: Data?
        var setupVisits = 0
        var receiverState = "正在启动"
        let receiver = PhoneScreenshotReceiver(token: "local-test-secret", port: port,
                                               shortcutData: shortcut, onImage: { data, completion in
            lock.lock()
            received = data
            lock.unlock()
            completion(.saved)
        }, onState: { status in
            lock.lock()
            receiverState = status
            lock.unlock()
        }, onSetupVisit: {
            lock.lock()
            setupVisits += 1
            lock.unlock()
        })
        try receiver.start()
        defer { receiver.stop() }

        waitForReady("initial") {
            lock.lock()
            defer { lock.unlock() }
            return receiverState
        }
        // URLSession handles the TCP connection and HTTP response as Shortcuts does.
        let address = "http://127.0.0.1:\(port)/v1/screenshot/"
        // NWListener.newConnectionLimit is a lifetime budget, not a concurrent
        // connection cap. Regressions must remain visible after eight requests.
        for attempt in 1...12 {
            let allowed = try post(payload, to: address + "local-test-secret")
            precondition(allowed == 200, "authorized upload \(attempt) failed: \(allowed)")
        }
        lock.lock()
        let recorded = received
        lock.unlock()
        precondition(recorded == payload, "uploaded bytes changed")
        let denied = try post(payload, to: address + "wrong-secret")
        precondition(denied == 403, "wrong pairing secret was accepted: \(denied)")
        let base = "http://127.0.0.1:\(port)"
        let (setupStatus, setupBody) = try get(base + "/v1/setup/local-test-secret")
        let setupPage = String(decoding: setupBody, as: UTF8.self)
        precondition(setupStatus == 200 &&
                     setupPage.contains("https://www.icloud.com/shortcuts/92f7bdc3a5554d1e9d560e0ed03a8879") &&
                     setupPage.contains("/v1/screenshot/local-test-secret") &&
                     setupPage.contains("中文地址占位文字") &&
                     setupPage.contains("不要复制浏览器地址栏里的安装页网址") &&
                     setupPage.contains("自动化已关闭"),
                     "authorized setup page was not served")
        let (shortcutStatus, shortcutBody) = try get(base + "/v1/shortcut/local-test-secret")
        precondition(shortcutStatus == 200 && shortcutBody == shortcut,
                     "shortcut download bytes changed")
        let (deniedSetup, _) = try get(base + "/v1/setup/wrong-secret")
        precondition(deniedSetup == 403, "wrong setup pairing secret was accepted")
        let (deniedShortcut, _) = try get(base + "/v1/shortcut/wrong-secret")
        precondition(deniedShortcut == 403, "wrong shortcut pairing secret was accepted")
        lock.lock()
        let authorizedSetupVisits = setupVisits
        lock.unlock()
        precondition(authorizedSetupVisits == 1,
                     "only the authorized setup page should update connection diagnostics")

        let defaultsName = "PhoneScreenshotTransportSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            fatalError("cannot create isolated pairing preferences")
        }
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let originalToken = PhoneScreenshotReceiver.token(in: defaults)
        let rotatedToken = PhoneScreenshotReceiver.rotateToken(in: defaults)
        precondition(originalToken.count == 32 && rotatedToken.count == 32 &&
                     originalToken != rotatedToken &&
                     PhoneScreenshotReceiver.token(in: defaults) == rotatedToken,
                     "pairing reset did not persist a fresh 128-bit token")

        receiver.stop()
        // NWListener releases its port asynchronously after cancel().
        Thread.sleep(forTimeInterval: 0.3)
        var rotatedState = "正在启动"
        let rotatedReceiver = PhoneScreenshotReceiver(
            token: rotatedToken, port: port, shortcutData: shortcut,
            onImage: { _, completion in completion(.saved) }, onState: { status in
                lock.lock()
                rotatedState = status
                lock.unlock()
            }
        )
        try rotatedReceiver.start()
        defer { rotatedReceiver.stop() }
        waitForReady("rotated") {
            lock.lock()
            defer { lock.unlock() }
            return rotatedState
        }
        let oldStatus = try post(payload, to: address + "local-test-secret")
        let newStatus = try post(payload, to: address + rotatedToken)
        precondition(oldStatus == 403 && newStatus == 200,
                     "rotated receiver must reject the previous upload URL")
        print("Phone screenshot transport smoke test passed")
    }

    private static func waitForReady(_ label: String, _ state: () -> String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = state()
            if current.hasPrefix("已就绪") { return }
            precondition(!current.hasPrefix("接收失败"), "\(label) listener failed: \(current)")
            Thread.sleep(forTimeInterval: 0.05)
        }
        preconditionFailure("\(label) listener did not become ready: \(state())")
    }

    private static func post(_ body: Data, to address: String) throws -> Int {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        let finished = DispatchSemaphore(value: 0)
        var status = -1
        var failure: Error?
        URLSession.shared.dataTask(with: request) { _, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            failure = error
            finished.signal()
        }.resume()
        precondition(finished.wait(timeout: .now() + 5) == .success, "request timed out")
        if let failure { throw failure }
        return status
    }

    private static func get(_ address: String) throws -> (Int, Data) {
        let finished = DispatchSemaphore(value: 0)
        var status = -1
        var body = Data()
        var failure: Error?
        URLSession.shared.dataTask(with: URL(string: address)!) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            body = data ?? Data()
            failure = error
            finished.signal()
        }.resume()
        precondition(finished.wait(timeout: .now() + 5) == .success, "request timed out")
        if let failure { throw failure }
        return (status, body)
    }
}
