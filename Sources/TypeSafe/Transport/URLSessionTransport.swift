import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The default transport, backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout.seconds
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw TypeSafeError.timeout(request.timeout.seconds)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TypeSafeError.connection(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TypeSafeError.connection(underlying: URLError(.badServerResponse))
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
