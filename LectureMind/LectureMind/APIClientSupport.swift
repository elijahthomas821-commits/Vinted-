import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors raised by the network-backed services (OpenAI Whisper and Anthropic Claude).
enum APIError: LocalizedError, Equatable {
    case missingAPIKey(service: String)
    case invalidResponse(service: String)
    case httpError(service: String, statusCode: Int, message: String, retryAfter: TimeInterval?)
    /// An error event delivered inside an otherwise successful (HTTP 200) streaming response.
    case serviceError(service: String, message: String)
    case network(service: String, message: String)
    case decodingFailed(service: String, details: String)
    case emptyResult(service: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let service):
            return "\(service) API key is missing. Add it in Settings."
        case .invalidResponse(let service):
            return "\(service) returned an invalid response."
        case .httpError(let service, let statusCode, let message, _):
            return "\(service) request failed (HTTP \(statusCode)): \(message)"
        case .serviceError(let service, let message):
            return "\(service) reported an error: \(message)"
        case .network(let service, let message):
            return "Could not reach \(service): \(message)"
        case .decodingFailed(let service, let details):
            return "Could not read the \(service) response: \(details)"
        case .emptyResult(let service):
            return "\(service) returned an empty result."
        }
    }

    /// Whether sending the same request again might succeed.
    var isRetryable: Bool {
        switch self {
        case .httpError(_, let statusCode, _, _):
            return statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
        case .network:
            return true
        default:
            return false
        }
    }

    /// Whether the failure means the API key itself was rejected, so retrying other
    /// requests with the same key is pointless.
    var isAuthenticationFailure: Bool {
        switch self {
        case .missingAPIKey:
            return true
        case .httpError(_, let statusCode, _, _):
            return statusCode == 401 || statusCode == 403
        default:
            return false
        }
    }

    /// Builds an `.httpError` from a non-2xx response. Both OpenAI and Anthropic wrap
    /// failures as `{"error": {"message": "..."}}`; anything else falls back to the status text.
    static func http(service: String, response: HTTPURLResponse, body: Data) -> APIError {
        let message = errorMessage(from: body)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        return .httpError(service: service, statusCode: response.statusCode, message: message, retryAfter: retryAfter)
    }

    static func errorMessage(from body: Data) -> String? {
        struct Envelope: Decodable {
            struct Details: Decodable { let message: String? }
            let error: Details?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
           let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Exponential-backoff retry for transient API failures (rate limits, 5xx, dropped connections).
struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var baseDelay: TimeInterval = 1.5
    var maxDelay: TimeInterval = 20

    static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)

    func delay(beforeAttempt attempt: Int, after error: APIError) -> TimeInterval {
        if case .httpError(_, _, _, let retryAfter?) = error {
            return min(max(retryAfter, 0), maxDelay)
        }
        let exponential = baseDelay * pow(2, Double(max(attempt - 2, 0)))
        return min(exponential, maxDelay)
    }

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as APIError where error.isRetryable && attempt < maxAttempts {
                attempt += 1
                let seconds = delay(beforeAttempt: attempt, after: error)
                if seconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }
    }
}

enum HTTPClient {
    /// Sends `request`, mapping transport failures and non-2xx responses to `APIError`.
    static func send(_ request: URLRequest, session: URLSession, service: String) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            throw mapTransportError(error, service: service)
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw APIError.invalidResponse(service: service)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(service: service, response: response, body: result.0)
        }
        return result.0
    }

    static func mapTransportError(_ error: URLError, service: String) -> Error {
        if error.code == .cancelled {
            return CancellationError()
        }
        return APIError.network(service: service, message: error.localizedDescription)
    }
}

/// Minimal `multipart/form-data` body builder for file uploads.
struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String = "LectureMind-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// The complete body including the closing boundary.
    func encoded() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
