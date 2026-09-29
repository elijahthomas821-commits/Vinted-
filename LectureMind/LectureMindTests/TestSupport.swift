import Foundation
import XCTest
@testable import LectureMind

struct TestError: Error, Equatable {}

// MARK: - HTTP stubbing

/// Serves canned HTTP responses to a `URLSession` built with `MockURLProtocol.makeSession()`.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    struct RecordedRequest {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    private static var responder: ((URLRequest, Int) throws -> Stub)?
    private static var requests: [RecordedRequest] = []

    /// Installs `responder`, which receives each request and its zero-based position.
    static func respond(with responder: @escaping (URLRequest, Int) throws -> Stub) {
        lock.lock()
        defer { lock.unlock() }
        self.responder = responder
        requests = []
    }

    static var recordedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.readBody(of: request)
        Self.lock.lock()
        let responder = Self.responder
        let position = Self.requests.count
        Self.requests.append(RecordedRequest(request: request, body: body))
        Self.lock.unlock()

        do {
            guard let responder, let url = request.url else { throw URLError(.badServerResponse) }
            let stub = try responder(request, position)
            let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Fakes for AppState

final class InMemoryKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [APIKeyKind: String]

    init(_ keys: [APIKeyKind: String] = [:]) {
        self.keys = keys
    }

    func apiKey(for kind: APIKeyKind) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[kind]
    }

    func setAPIKey(_ value: String?, for kind: APIKeyKind) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        keys[kind] = trimmed.isEmpty ? nil : trimmed
    }
}

/// Stands in for ScreenCaptureKit: tests push chunks and events by hand.
final class FakeAudioCapture: AudioCapturing {
    var permissionGranted = true
    var startError: Error?
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var onEvent: (@Sendable (CaptureEvent) -> Void)?

    func hasScreenCapturePermission() -> Bool { permissionGranted }

    func requestScreenCapturePermission() -> Bool {
        permissionRequestCount += 1
        return permissionGranted
    }

    @MainActor
    func start(onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        self.onEvent = onEvent
        return stream
    }

    @MainActor
    func stop() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func removeTemporaryFiles() {}

    func emitChunk(index: Int, startTime: TimeInterval) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(Self.fileName(for: index))
        continuation?.yield(AudioChunk(index: index, fileURL: url, startTime: startTime, duration: 30))
    }

    func send(_ event: CaptureEvent) {
        onEvent?(event)
    }

    static func fileName(for index: Int) -> String {
        "fake-chunk-\(index).wav"
    }
}

actor FakeTranscriber: TranscriptionServiceProtocol {
    struct Call: Equatable {
        let fileName: String
        let prompt: String?
    }

    private var failuresRemaining: [String: Int]
    private let failure: Error
    private let prepareError: Error?
    private(set) var calls: [Call] = []
    private(set) var prepareCount = 0

    init(failuresRemaining: [String: Int] = [:], failure: Error = TestError(), prepareError: Error? = nil) {
        self.failuresRemaining = failuresRemaining
        self.failure = failure
        self.prepareError = prepareError
    }

    func prepare() async throws {
        prepareCount += 1
        if let prepareError { throw prepareError }
    }

    func transcribe(audioFileURL: URL, prompt: String?) async throws -> String {
        let name = audioFileURL.lastPathComponent
        calls.append(Call(fileName: name, prompt: prompt))
        if let remaining = failuresRemaining[name], remaining > 0 {
            failuresRemaining[name] = remaining - 1
            throw failure
        }
        return FakeTranscriber.text(for: name)
    }

    static func text(for fileName: String) -> String {
        "Spoken words from \(fileName)"
    }
}

final class FakeNoteGenerator: NoteGeneratorServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let updates: [NoteGenerationUpdate]
    private let failure: Error?
    private var recordedRequests: [NoteRequest] = []

    convenience init(fragments: [String] = ["# Sorting Algorithms\n\n", "## Executive Summary\n", "Covered quicksort."], failure: Error? = nil) {
        self.init(updates: fragments.map(NoteGenerationUpdate.text), failure: failure)
    }

    init(updates: [NoteGenerationUpdate], failure: Error? = nil) {
        self.updates = updates
        self.failure = failure
    }

    var requests: [NoteRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func generateNotes(for request: NoteRequest) -> AsyncThrowingStream<NoteGenerationUpdate, Error> {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
        let updates = updates
        let failure = failure
        return AsyncThrowingStream { continuation in
            for update in updates {
                continuation.yield(update)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Timed out waiting for condition")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
