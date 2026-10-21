import Foundation

/// A small, bounded HTTP/1.1 parser for the local screenshot receiver. It
/// accepts one request per connection and never buffers an unbounded body.
final class PhoneScreenshotHTTPParser {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    enum ParseError: Error {
        case invalidRequest
        case lengthRequired
        case tooLarge
    }

    private(set) var requestLine: (method: String, path: String)?
    private(set) var headers: [String: String] = [:]
    private(set) var expectsContinue = false
    private var buffer = Data()
    private var body = Data()
    private var contentLength: Int?
    private var isChunked = false
    private var nextChunkLength: Int?
    private let maximumBodyBytes: Int

    init(maximumBodyBytes: Int) {
        self.maximumBodyBytes = maximumBodyBytes
    }

    func append(_ received: Data) throws -> Request? {
        buffer.append(received)
        if requestLine == nil {
            guard let boundary = buffer.range(of: Data([13, 10, 13, 10])) else {
                if buffer.count > 16_384 { throw ParseError.invalidRequest }
                return nil
            }
            guard boundary.lowerBound <= 16_384,
                  let headerText = String(data: buffer[..<boundary.lowerBound], encoding: .isoLatin1)
            else { throw ParseError.invalidRequest }
            buffer.removeSubrange(..<boundary.upperBound)
            let lines = headerText.components(separatedBy: "\r\n")
            guard let first = lines.first else { throw ParseError.invalidRequest }
            let parts = first.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3, parts[2] == "HTTP/1.1",
                  parts[0] == "POST", parts[1].hasPrefix("/")
            else { throw ParseError.invalidRequest }
            requestLine = (String(parts[0]), String(parts[1]))
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw ParseError.invalidRequest }
                let name = line[..<colon].lowercased()
                guard !name.isEmpty, headers[name] == nil else { throw ParseError.invalidRequest }
                headers[name] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            expectsContinue = headers["expect"]?.lowercased() == "100-continue"
            if let encoding = headers["transfer-encoding"]?.lowercased() {
                guard encoding == "chunked", headers["content-length"] == nil else {
                    throw ParseError.invalidRequest
                }
                isChunked = true
            } else if let rawLength = headers["content-length"], let length = Int(rawLength), length >= 0 {
                guard length <= maximumBodyBytes else { throw ParseError.tooLarge }
                contentLength = length
            } else {
                throw ParseError.lengthRequired
            }
        }

        guard let requestLine else { return nil }
        if let contentLength {
            guard buffer.count >= contentLength else { return nil }
            return Request(method: requestLine.method, path: requestLine.path,
                           headers: headers, body: Data(buffer.prefix(contentLength)))
        }

        while isChunked {
            if nextChunkLength == nil {
                guard let lineEnd = buffer.range(of: Data([13, 10])) else {
                    if buffer.count > 128 { throw ParseError.invalidRequest }
                    return nil
                }
                guard lineEnd.lowerBound <= 128,
                      let line = String(data: buffer[..<lineEnd.lowerBound], encoding: .ascii),
                      let hex = line.split(separator: ";", maxSplits: 1).first,
                      let length = Int(hex, radix: 16), length >= 0
                else { throw ParseError.invalidRequest }
                guard length <= maximumBodyBytes - body.count else { throw ParseError.tooLarge }
                buffer.removeSubrange(..<lineEnd.upperBound)
                nextChunkLength = length
            }
            guard let length = nextChunkLength else { return nil }
            guard buffer.count >= length + 2 else { return nil }
            guard buffer[length] == 13, buffer[length + 1] == 10 else {
                throw ParseError.invalidRequest
            }
            if length == 0 {
                return Request(method: requestLine.method, path: requestLine.path,
                               headers: headers, body: body)
            }
            body.append(contentsOf: buffer.prefix(length))
            buffer.removeSubrange(..<(length + 2))
            nextChunkLength = nil
        }
        return nil
    }
}
