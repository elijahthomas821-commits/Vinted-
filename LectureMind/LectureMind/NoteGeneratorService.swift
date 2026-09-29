import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Input for note generation: the accumulated transcript plus recording metadata.
struct NoteRequest: Sendable, Equatable {
    let transcript: String
    let recordedAt: Date
    let duration: TimeInterval
}

/// One step of note generation.
enum NoteGenerationUpdate: Equatable, Sendable {
    /// Markdown to append to the notes.
    case text(String)
    /// A human-readable status line, e.g. "Summarizing part 2 of 5…".
    case progress(String)
}

/// Which model writes the notes.
enum NoteEngine: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence (free)"
        case .claude: return "Claude (API key)"
        }
    }
}

/// Turns a raw lecture transcript into structured Markdown notes.
protocol NoteGeneratorServiceProtocol: Sendable {
    /// Streams the Markdown notes as incremental text fragments, interleaved with progress.
    func generateNotes(for request: NoteRequest) -> AsyncThrowingStream<NoteGenerationUpdate, Error>
}

enum NotePrompt {
    static let system = """
    You are an elite academic assistant. You turn raw lecture transcripts into clear, accurate, \
    well-organized study notes that a diligent student would be proud of.

    About the input:
    - The transcript comes from automatic speech recognition of audio played on the listener's computer.
    - It is split into roughly 30-second segments, each prefixed with an approximate [mm:ss] timestamp.
    - Expect recognition errors, missing punctuation, filler words, and words cut at segment boundaries.

    How to work:
    - Reconstruct the lecturer's intended meaning. Silently fix obvious recognition errors, especially \
    technical terms, names, and formulas, using the surrounding context.
    - Stay faithful to the lecture. Never invent facts, examples, dates, or assignments that were not said. \
    If something important is ambiguous, keep it and mark it "(unclear in recording)".
    - Prefer precise, information-dense bullets over prose. Preserve definitions, formulas, numbers, \
    worked examples, and anything the lecturer emphasized (for example "this will be on the exam").
    - Write math inline as LaTeX between single dollar signs, e.g. $E = mc^2$.

    Output only Markdown, using exactly these headings in this order:

    # <Lecture title or topic, inferred from the content>

    ## Executive Summary
    Three to six sentences on the lecture's purpose, main arguments, and conclusions.

    ## Key Concepts & Definitions
    - **Term** — concise definition as used in this lecture.

    ## Detailed Lecture Breakdown (Bulleted)
    Follow the order of the lecture. Start each sub-topic with a bold line that includes the approximate \
    [mm:ss] timestamp where it begins, followed by nested bullets for supporting details, examples, and derivations.

    ## Action Items, Assignments & Key Dates
    - [ ] Every task, reading, assignment, exam, or deadline mentioned, with its due date if stated.
    If none were mentioned, write "- None mentioned in this lecture."

    Do not add any preamble, closing remarks, or code fences around the notes.
    """

    static func userMessage(for request: NoteRequest) -> String {
        let date = DateFormatter.localizedString(from: request.recordedAt, dateStyle: .full, timeStyle: .short)
        return """
        Lecture recorded \(date). Recording length: \(TimeFormatting.clock(request.duration)).

        <transcript>
        \(request.transcript)
        </transcript>

        Write the structured lecture notes for this transcript.
        """
    }
}

// MARK: - Anthropic Claude

/// Generates notes with the Anthropic Messages API, streaming the response so the notes
/// appear while they are written and long generations never hit an idle timeout.
/// API reference: https://docs.anthropic.com/en/api/messages
struct AnthropicNoteGeneratorService: NoteGeneratorServiceProtocol {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let defaultModel = "claude-opus-5-5"
    static let serviceName = "Anthropic"

    let apiKey: String
    var model = AnthropicNoteGeneratorService.defaultModel
    var maxTokens = 8192
    var session: URLSession = .shared
    var retryPolicy = RetryPolicy()

    func generateNotes(for request: NoteRequest) -> AsyncThrowingStream<NoteGenerationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamNotes(for: request) { continuation.yield(.text($0)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(for request: NoteRequest, apiKey: String) throws -> URLRequest {
        let body = MessagesRequest(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultModel : model,
            maxTokens: maxTokens,
            system: NotePrompt.system,
            messages: [.init(role: "user", content: NotePrompt.userMessage(for: request))],
            stream: true
        )
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func streamNotes(for request: NoteRequest, onText: (String) -> Void) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw APIError.missingAPIKey(service: Self.serviceName)
        }
        let urlRequest = try makeURLRequest(for: request, apiKey: key)

        // Only opening the stream is retried; once text has been delivered a retry would duplicate it.
        let bytes = try await retryPolicy.run { try await openStream(urlRequest) }

        var parser = AnthropicStreamParser()
        do {
            for try await line in bytes.lines {
                if let text = try parser.consume(line: line) {
                    onText(text)
                }
            }
        } catch let error as URLError {
            throw HTTPClient.mapTransportError(error, service: Self.serviceName)
        }

        guard parser.isComplete else {
            throw APIError.network(service: Self.serviceName, message: "The response ended before the notes were complete.")
        }
        if parser.stopReason == "max_tokens" {
            onText("\n\n> _Notes were cut short because the model reached its output limit._\n")
        }
    }

    private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.bytes(for: request)
        } catch let error as URLError {
            throw HTTPClient.mapTransportError(error, service: Self.serviceName)
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw APIError.invalidResponse(service: Self.serviceName)
        }
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await byte in result.0 {
                body.append(byte)
                if body.count >= 64_000 { break }
            }
            throw APIError.http(service: Self.serviceName, response: response, body: body)
        }
        return result.0
    }

    struct MessagesRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream
            case maxTokens = "max_tokens"
        }
    }
}

/// Incremental parser for the Messages API server-sent events stream. Each `data:` line
/// carries a complete JSON event, so lines can be handled independently of `event:` lines
/// and blank separators.
struct AnthropicStreamParser {
    private(set) var stopReason: String?
    private(set) var isComplete = false

    /// Consumes one line of the stream and returns any text it adds to the response.
    mutating func consume(line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty,
              let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8)) else {
            return nil
        }

        switch event.type {
        case "content_block_delta":
            if event.delta?.type == "text_delta" {
                return event.delta?.text
            }
        case "message_delta":
            if let reason = event.delta?.stopReason {
                stopReason = reason
            }
        case "message_stop":
            isComplete = true
        case "error":
            let message = event.error?.message ?? event.error?.type ?? "Unknown streaming error"
            throw APIError.serviceError(service: AnthropicNoteGeneratorService.serviceName, message: message)
        default:
            break  // message_start, content_block_start/stop, ping, and future event types.
        }
        return nil
    }

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }

        struct ErrorDetails: Decodable {
            let type: String?
            let message: String?
        }

        let type: String
        let delta: Delta?
        let error: ErrorDetails?
    }
}
