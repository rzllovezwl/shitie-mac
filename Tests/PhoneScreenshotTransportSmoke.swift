import Foundation

@main
struct PhoneScreenshotTransportSmoke {
    static func main() throws {
        let port: UInt16 = 52782
        let payload = Data([0x89, 0x50, 0x4e, 0x47])
        let shortcut = Data("signed-shortcut-fixture".utf8)
        let lock = NSLock()
        var received: Data?
        let receiver = PhoneScreenshotReceiver(token: "local-test-secret", port: port,
                                               shortcutData: shortcut, onImage: { data, completion in
            lock.lock()
            received = data
            lock.unlock()
            completion(.saved)
        }, onState: { _ in })
        try receiver.start()
        defer { receiver.stop() }

        // A bound listener normally becomes ready in milliseconds. URLSession
        // handles the TCP connection and the HTTP response just as Shortcuts does.
        Thread.sleep(forTimeInterval: 0.3)
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
        print("Phone screenshot transport smoke test passed")
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
