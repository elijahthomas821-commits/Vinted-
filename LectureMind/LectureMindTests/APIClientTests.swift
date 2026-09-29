import XCTest
@testable import LectureMind

final class APIClientTests: XCTestCase {
    private var audioFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        audioFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString).wav")
        try AudioProcessing.wavData(samples: [1, 2, 3, 4], sampleRate: 16_000).write(to: audioFileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: audioFileURL)
        try super.tearDownWithError()
    }

    // MARK: Whisper

    func testWhisperSendsMultipartRequestAndParsesTranscript() async throws {
        MockURLProtocol.respond { _, _ in
            MockURLProtocol.Stub(body: Data(#"{"text": "  Today we cover entropy.  "}"#.utf8))
        }
        let service = OpenAIWhisperTranscriptionService(
            apiKey: " sk-test ",
            language: "EN",
            session: MockURLProtocol.makeSession(),
            retryPolicy: .none
        )

        let text = try await service.transcribe(audioFileURL: audioFileURL, prompt: "Previously: thermodynamics")

        XCTAssertEqual(text, "Today we cover entropy.")
        let recorded = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(recorded.request.url, OpenAIWhisperTranscriptionService.endpoint)
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let contentType = try XCTUnwrap(recorded.request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = String(decoding: recorded.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nPreviously: thermodynamics\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\nRIFF"))
        let boundary = contentType.components(separatedBy: "boundary=").last ?? ""
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testWhisperSurfacesAPIErrorMessage() async {
        MockURLProtocol.respond { _, _ in
            MockURLProtocol.Stub(statusCode: 401, body: Data(#"{"error": {"message": "Incorrect API key provided.", "type": "invalid_request_error"}}"#.utf8))
        }
        let service = OpenAIWhisperTranscriptionService(apiKey: "sk-bad", session: MockURLProtocol.makeSession())

        do {
            _ = try await service.transcribe(audioFileURL: audioFileURL, prompt: nil)
            XCTFail("Expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .httpError(service: "OpenAI", statusCode: 401, message: "Incorrect API key provided.", retryAfter: nil))
            XCTAssertTrue(error.isAuthenticationFailure)
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 1, "401 must not be retried")
    }

    func testWhisperRetriesTransientFailures() async throws {
        MockURLProtocol.respond { _, attempt in
            attempt == 0
                ? MockURLProtocol.Stub(statusCode: 503, body: Data("upstream unavailable".utf8))
                : MockURLProtocol.Stub(body: Data(#"{"text":"Recovered"}"#.utf8))
        }
        let service = OpenAIWhisperTranscriptionService(
            apiKey: "sk-test",
            session: MockURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0)
        )

        let text = try await service.transcribe(audioFileURL: audioFileURL, prompt: nil)

        XCTAssertEqual(text, "Recovered")
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 2)
    }

    func testWhisperRequiresAPIKey() async {
        let service = OpenAIWhisperTranscriptionService(apiKey: "   ")
        do {
            _ = try await service.transcribe(audioFileURL: audioFileURL, prompt: nil)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .missingAPIKey(service: "OpenAI"))
        }
    }

    func testWhisperReportsUnreadableAudio() async {
        let service = OpenAIWhisperTranscriptionService(apiKey: "sk-test", session: MockURLProtocol.makeSession())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")
        do {
            _ = try await service.transcribe(audioFileURL: missing, prompt: nil)
            XCTFail("Expected an error")
        } catch {
            guard case .unreadableAudio? = error as? TranscriptionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: Transcription fallback

    func testFallbackTranscriptionUsesSecondaryService() async throws {
        let failing = FakeTranscriber(failuresRemaining: [audioFileURL.lastPathComponent: 1])
        let working = FakeTranscriber()
        let service = FallbackTranscriptionService(primary: failing, fallback: working)

        let text = try await service.transcribe(audioFileURL: audioFileURL, prompt: nil)

        XCTAssertEqual(text, FakeTranscriber.text(for: audioFileURL.lastPathComponent))
    }

    func testFallbackToUnavailableLocalEngineRethrowsPrimaryError() async {
        let failing = FakeTranscriber(failuresRemaining: [audioFileURL.lastPathComponent: 1])
        let service = FallbackTranscriptionService(primary: failing, fallback: LocalWhisperKitTranscriptionService())
        do {
            _ = try await service.transcribe(audioFileURL: audioFileURL, prompt: nil)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TestError, TestError())
        }
    }

    // MARK: Claude

    func testClaudeStreamsNotesFromServerSentEvents() async throws {
        MockURLProtocol.respond { _, _ in
            MockURLProtocol.Stub(headers: ["Content-Type": "text/event-stream"], body: Data(Self.successfulStream.utf8))
        }
        let service = AnthropicNoteGeneratorService(apiKey: "ak-test", model: "claude-test-model", session: MockURLProtocol.makeSession())
        let request = NoteRequest(transcript: "[00:00] Welcome to thermodynamics.", recordedAt: Date(), duration: 3_600)

        var notes = ""
        for try await update in service.generateNotes(for: request) {
            if case .text(let fragment) = update { notes += fragment }
        }

        XCTAssertEqual(notes, "# Thermodynamics\n\n## Executive Summary\nEnergy is conserved.")
        let recorded = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(recorded.request.url, AnthropicNoteGeneratorService.endpoint)
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "x-api-key"), "ak-test")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-test-model")
        XCTAssertEqual(json["max_tokens"] as? Int, 8192)
        XCTAssertEqual(json["stream"] as? Bool, true)
        let system = try XCTUnwrap(json["system"] as? String)
        for heading in ["## Executive Summary", "## Key Concepts & Definitions", "## Detailed Lecture Breakdown (Bulleted)", "## Action Items, Assignments & Key Dates"] {
            XCTAssertTrue(system.contains(heading), "System prompt is missing \(heading)")
        }
        XCTAssertTrue(system.contains("elite academic assistant"))
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let content = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(content.contains("<transcript>\n[00:00] Welcome to thermodynamics.\n</transcript>"))
        XCTAssertTrue(content.contains("Recording length: 1:00:00"))
    }

    func testClaudeHTTPErrorIsParsed() async {
        MockURLProtocol.respond { _, _ in
            MockURLProtocol.Stub(statusCode: 529, body: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
        }
        let service = AnthropicNoteGeneratorService(apiKey: "ak-test", session: MockURLProtocol.makeSession(), retryPolicy: .none)

        do {
            for try await _ in service.generateNotes(for: Self.sampleRequest) {}
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .httpError(service: "Anthropic", statusCode: 529, message: "Overloaded", retryAfter: nil))
            XCTAssertTrue((error as? APIError)?.isRetryable ?? false)
        }
    }

    func testClaudeRetriesRateLimitBeforeStreaming() async throws {
        MockURLProtocol.respond { _, attempt in
            attempt == 0
                ? MockURLProtocol.Stub(statusCode: 429, headers: ["retry-after": "0"], body: Data(#"{"error":{"message":"Rate limited"}}"#.utf8))
                : MockURLProtocol.Stub(body: Data(Self.successfulStream.utf8))
        }
        let service = AnthropicNoteGeneratorService(
            apiKey: "ak-test",
            session: MockURLProtocol.makeSession(),
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0)
        )

        var notes = ""
        for try await update in service.generateNotes(for: Self.sampleRequest) {
            if case .text(let fragment) = update { notes += fragment }
        }

        XCTAssertTrue(notes.hasPrefix("# Thermodynamics"))
        XCTAssertEqual(MockURLProtocol.recordedRequests.count, 2)
    }

    func testClaudeStreamErrorEventThrows() async {
        let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[]}}

        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """
        MockURLProtocol.respond { _, _ in MockURLProtocol.Stub(body: Data(stream.utf8)) }
        let service = AnthropicNoteGeneratorService(apiKey: "ak-test", session: MockURLProtocol.makeSession(), retryPolicy: .none)

        do {
            for try await _ in service.generateNotes(for: Self.sampleRequest) {}
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .serviceError(service: "Anthropic", message: "Overloaded"))
        }
    }

    func testClaudeTruncatedStreamThrows() async {
        let stream = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"# Partial"}}

        """
        MockURLProtocol.respond { _, _ in MockURLProtocol.Stub(body: Data(stream.utf8)) }
        let service = AnthropicNoteGeneratorService(apiKey: "ak-test", session: MockURLProtocol.makeSession(), retryPolicy: .none)

        var received = ""
        do {
            for try await update in service.generateNotes(for: Self.sampleRequest) {
                if case .text(let fragment) = update { received += fragment }
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(received, "# Partial")
            guard case .network? = error as? APIError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testClaudeRequiresAPIKey() async {
        let service = AnthropicNoteGeneratorService(apiKey: "")
        do {
            for try await _ in service.generateNotes(for: Self.sampleRequest) {}
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .missingAPIKey(service: "Anthropic"))
        }
    }

    // MARK: Stream parser

    func testStreamParserTracksStopReason() throws {
        var parser = AnthropicStreamParser()
        XCTAssertNil(try parser.consume(line: "event: message_delta"))
        XCTAssertNil(try parser.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#))
        XCTAssertEqual(parser.stopReason, "max_tokens")
        XCTAssertFalse(parser.isComplete)
        XCTAssertNil(try parser.consume(line: #"data: {"type":"message_stop"}"#))
        XCTAssertTrue(parser.isComplete)
    }

    func testStreamParserIgnoresNonTextDeltasAndMalformedLines() throws {
        var parser = AnthropicStreamParser()
        XCTAssertNil(try parser.consume(line: ""))
        XCTAssertNil(try parser.consume(line: "data: not json"))
        XCTAssertNil(try parser.consume(line: #"data: {"type":"ping"}"#))
        XCTAssertNil(try parser.consume(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#))
        XCTAssertEqual(try parser.consume(line: #"data:{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), "Hi")
    }

    // MARK: Shared helpers

    func testMultipartEncoding() {
        var form = MultipartFormData(boundary: "XYZ")
        form.addField(name: "model", value: "whisper-1")
        form.addFile(name: "file", fileName: "a.wav", mimeType: "audio/wav", data: Data("DATA".utf8))
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=XYZ")
        XCTAssertEqual(
            String(decoding: form.encoded(), as: UTF8.self),
            "--XYZ\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
                + "--XYZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\nDATA\r\n"
                + "--XYZ--\r\n"
        )
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(APIError.errorMessage(from: Data(#"{"error":{"message":"Bad key"}}"#.utf8)), "Bad key")
        XCTAssertEqual(APIError.errorMessage(from: Data("plain failure".utf8)), "plain failure")
        XCTAssertNil(APIError.errorMessage(from: Data()))
    }

    func testRetryPolicyStopsOnNonRetryableErrors() async {
        var attempts = 0
        do {
            _ = try await RetryPolicy(maxAttempts: 5, baseDelay: 0, maxDelay: 0).run { () async throws -> Int in
                attempts += 1
                throw APIError.missingAPIKey(service: "OpenAI")
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testRetryPolicyGivesUpAfterMaxAttempts() async {
        var attempts = 0
        do {
            _ = try await RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0).run { () async throws -> Int in
                attempts += 1
                throw APIError.network(service: "OpenAI", message: "offline")
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(attempts, 3)
        }
    }

    func testRetryDelayHonorsRetryAfterAndBackoff() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 10)
        let rateLimited = APIError.httpError(service: "Anthropic", statusCode: 429, message: "", retryAfter: 7)
        XCTAssertEqual(policy.delay(beforeAttempt: 2, after: rateLimited), 7)
        let serverError = APIError.httpError(service: "Anthropic", statusCode: 500, message: "", retryAfter: nil)
        XCTAssertEqual(policy.delay(beforeAttempt: 2, after: serverError), 1)
        XCTAssertEqual(policy.delay(beforeAttempt: 3, after: serverError), 2)
        XCTAssertEqual(policy.delay(beforeAttempt: 9, after: serverError), 10)
    }

    // MARK: Fixtures

    private static let sampleRequest = NoteRequest(transcript: "[00:00] Hello.", recordedAt: Date(timeIntervalSince1970: 0), duration: 60)

    private static let successfulStream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"claude-test-model","stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"# Thermodynamics\\n\\n"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"## Executive Summary\\nEnergy is conserved."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}

    event: message_stop
    data: {"type":"message_stop"}

    """
}
