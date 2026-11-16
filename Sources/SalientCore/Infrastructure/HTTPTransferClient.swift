import Foundation

public struct HTTPTransferResponse: Equatable, Sendable {
    public var statusCode: Int
    public var expectedContentLength: Int64?

    public init(statusCode: Int, expectedContentLength: Int64? = nil) {
        self.statusCode = statusCode
        self.expectedContentLength = expectedContentLength
    }
}

public protocol HTTPTransferClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPTransferResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPTransferResponse)
}

public struct URLSessionHTTPTransferClient: HTTPTransferClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPTransferResponse) {
        let (data, response) = try await session.data(for: request)
        return (data, try Self.transferResponse(response))
    }

    public func download(for request: URLRequest) async throws -> (URL, HTTPTransferResponse) {
        let (url, response) = try await session.download(for: request)
        return (url, try Self.transferResponse(response))
    }

    private static func transferResponse(_ response: URLResponse) throws -> HTTPTransferResponse {
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let contentLength = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        return HTTPTransferResponse(statusCode: response.statusCode, expectedContentLength: contentLength)
    }
}
