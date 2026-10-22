import Foundation

private func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

@main
struct PhoneScreenshotSmoke {
    static func main() throws {
        let body = Data([0x89, 0x50, 0x4e, 0x47])
        let request = Data("POST /v1/screenshot/secret HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8) + body
        let parser = PhoneScreenshotHTTPParser(maximumBodyBytes: 8)
        require(try parser.append(request.prefix(20)) == nil, "partial header must wait")
        let parsed = try parser.append(request.dropFirst(20))
        require(parsed?.body == body, "binary body changed")
        require(parsed?.path == "/v1/screenshot/secret", "path changed")

        let chunked = PhoneScreenshotHTTPParser(maximumBodyBytes: 8)
        let chunkedRequest = Data("POST /v1/screenshot/secret HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n".utf8)
        require(try chunked.append(chunkedRequest) == nil, "chunked request ended early")
        let result = try chunked.append(Data("AB\r\n2\r\nCD\r\n0\r\n\r\n".utf8))
        require(result?.body == Data("ABCD".utf8), "chunked body changed")

        let oversized = PhoneScreenshotHTTPParser(maximumBodyBytes: 3)
        do {
            _ = try oversized.append(request)
            preconditionFailure("oversized request was accepted")
        } catch PhoneScreenshotHTTPParser.ParseError.tooLarge {}

        let missingLength = PhoneScreenshotHTTPParser(maximumBodyBytes: 8)
        do {
            _ = try missingLength.append(Data("POST /v1/screenshot/secret HTTP/1.1\r\n\r\n".utf8))
            preconditionFailure("request without a length was accepted")
        } catch PhoneScreenshotHTTPParser.ParseError.lengthRequired {}

        let get = PhoneScreenshotHTTPParser(maximumBodyBytes: 8)
        let setup = try get.append(Data("GET /v1/setup/secret HTTP/1.1\r\nHost: local\r\n\r\n".utf8))
        require(setup?.method == "GET" && setup?.body.isEmpty == true,
                "setup GET must work without Content-Length")

        let getWithBody = PhoneScreenshotHTTPParser(maximumBodyBytes: 8)
        do {
            _ = try getWithBody.append(Data("GET /v1/setup/secret HTTP/1.1\r\nContent-Length: 1\r\n\r\nX".utf8))
            preconditionFailure("GET with a body was accepted")
        } catch PhoneScreenshotHTTPParser.ParseError.invalidRequest {}

        print("Phone screenshot HTTP smoke test passed")
    }
}
