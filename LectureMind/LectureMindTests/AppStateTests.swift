import Combine
import XCTest
@testable import LectureMind

final class AppStateTests: XCTestCase {
    @MainActor
    private func makeState(
        capture: FakeAudioCapture = FakeAudioCapture(),
        keys: [APIKeyKind: String] = [.openAI: "sk-test", .anthropic: "ak-test"],
        transcriptionEngine: TranscriptionEngine? = nil,
        noteEngine: NoteEngine? = nil,
        transcriber: FakeTranscriber = FakeTranscriber(),
        generator: FakeNoteGenerator = FakeNoteGenerator(),
        appleIntelligenceUnavailability: String? = nil,
        archive: SessionArchive? = nil,
        recorder: ConfigurationRecorder? = nil
    ) -> AppState {
        let defaults = UserDefaults(suiteName: "LectureMindTests-\(UUID().uuidString)")!
        if let transcriptionEngine {
            defaults.set(transcriptionEngine.rawValue, forKey: SettingsKeys.transcriptionEngine)
        }
        if let noteEngine {
            defaults.set(noteEngine.rawValue, forKey: SettingsKeys.noteEngine)
        }
        return AppState(
            capture: capture,
            keyStore: InMemoryKeyStore(keys),
            defaults: defaults,
            archive: archive,
            makeTranscriber: { configuration in
                recorder?.transcribers.append(configuration)
                return transcriber
            },
            makeNoteGenerator: { configuration in
                recorder?.noteGenerators.append(configuration)
                return generator
            },
            appleIntelligenceUnavailability: { appleIntelligenceUnavailability }
        )
    }

    @MainActor
    final class ConfigurationRecorder {
        var transcribers: [TranscriberConfiguration] = []
        var noteGenerators: [NoteGeneratorConfiguration] = []
    }

    @MainActor
    func testFreeEnginesAreTheDefaultAndNeedNoAPIKeys() async {
        let capture = FakeAudioCapture()
        let recorder = ConfigurationRecorder()
        let transcriber = FakeTranscriber()
        let state = makeState(capture: capture, keys: [:], transcriber: transcriber, recorder: recorder)

        XCTAssertEqual(state.transcriptionEngine, .appleOnDevice)
        XCTAssertEqual(state.noteEngine, .appleIntelligence)

        await state.startRecording()
        XCTAssertEqual(state.status, .recording)
        XCTAssertNil(state.warning)
        let prepareCount = await transcriber.prepareCount
        XCTAssertEqual(prepareCount, 1, "The on-device engine must be prepared before capture starts")

        capture.emitChunk(index: 0, startTime: 0)
        await state.stopAndGenerateNotes()

        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(recorder.transcribers, [TranscriberConfiguration(engine: .appleOnDevice, apiKey: nil, language: nil)])
        XCTAssertEqual(recorder.noteGenerators.map(\.engine), [.appleIntelligence])
        XCTAssertNil(recorder.noteGenerators.first?.apiKey)
    }

    @MainActor
    func testTranscriberPreparationFailureStopsStart() async {
        let capture = FakeAudioCapture()
        let state = makeState(capture: capture, transcriber: FakeTranscriber(prepareError: OnDeviceTranscriptionError.permissionDenied))

        await state.startRecording()

        XCTAssertEqual(state.status, .error(OnDeviceTranscriptionError.permissionDenied.localizedDescription))
        XCTAssertTrue(state.needsSpeechPermission)
        XCTAssertEqual(capture.startCount, 0)
    }

    @MainActor
    func testUnavailableAppleIntelligenceWarnsAndKeepsTranscript() async {
        let capture = FakeAudioCapture()
        let generator = FakeNoteGenerator()
        let state = makeState(capture: capture, generator: generator, appleIntelligenceUnavailability: "Apple Intelligence is turned off.")

        await state.startRecording()
        XCTAssertTrue(state.warning?.contains("Apple Intelligence is turned off.") ?? false)
        capture.emitChunk(index: 0, startTime: 0)
        await state.stopAndGenerateNotes()

        guard case .error(let message) = state.status else {
            return XCTFail("Expected an error, got \(state.status)")
        }
        XCTAssertTrue(message.contains("Apple Intelligence is turned off."))
        XCTAssertTrue(message.contains(" in Settings"))
        XCTAssertFalse(state.transcript.isEmpty)
        XCTAssertTrue(generator.requests.isEmpty)
    }

    @MainActor
    func testNoteProgressIsPublishedAndClearedAfterwards() async {
        let capture = FakeAudioCapture()
        let generator = FakeNoteGenerator(updates: [.progress("Summarizing part 1 of 1…"), .text("# Title\n\n## Executive Summary\nDone.")])
        let state = makeState(capture: capture, generator: generator)
        var progressSeen: [String?] = []
        let subscription = state.$notesProgress.sink { progressSeen.append($0) }
        defer { subscription.cancel() }

        await state.startRecording()
        capture.emitChunk(index: 0, startTime: 0)
        await state.stopAndGenerateNotes()

        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(state.notes, "# Title\n\n## Executive Summary\nDone.")
        XCTAssertTrue(progressSeen.contains("Summarizing part 1 of 1…"))
        XCTAssertNil(state.notesProgress)
    }

    @MainActor
    func testFullSessionTranscribesChunksInOrderAndGeneratesNotes() async {
        let capture = FakeAudioCapture()
        let transcriber = FakeTranscriber()
        let generator = FakeNoteGenerator()
        let state = makeState(capture: capture, transcriber: transcriber, generator: generator)

        await state.startRecording()
        XCTAssertEqual(state.status, .recording)
        XCTAssertNotNil(state.recordingStartedAt)

        capture.emitChunk(index: 0, startTime: 0)
        capture.emitChunk(index: 1, startTime: 30)
        await state.stopAndGenerateNotes()

        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(capture.stopCount, 1)
        let first = FakeTranscriber.text(for: FakeAudioCapture.fileName(for: 0))
        let second = FakeTranscriber.text(for: FakeAudioCapture.fileName(for: 1))
        XCTAssertEqual(state.transcript, "[00:00] \(first)\n\n[00:30] \(second)")
        XCTAssertEqual(state.notes, "# Sorting Algorithms\n\n## Executive Summary\nCovered quicksort.")
        XCTAssertNil(state.warning)

        // The second chunk is transcribed with the first chunk's text as context.
        let calls = await transcriber.calls
        XCTAssertEqual(calls, [
            .init(fileName: FakeAudioCapture.fileName(for: 0), prompt: nil),
            .init(fileName: FakeAudioCapture.fileName(for: 1), prompt: first),
        ])
        XCTAssertEqual(generator.requests.map(\.transcript), [state.transcript])
    }

    @MainActor
    func testFailedChunkIsRetriedAfterStopAndKeepsTranscriptOrder() async throws {
        let capture = FakeAudioCapture()
        let transcriber = FakeTranscriber(failuresRemaining: [FakeAudioCapture.fileName(for: 0): 1])
        let state = makeState(capture: capture, transcriber: transcriber)

        await state.startRecording()
        capture.emitChunk(index: 0, startTime: 0)
        capture.emitChunk(index: 1, startTime: 30)
        try await waitUntil { state.warning != nil && state.transcript.contains("[00:30]") }
        XCTAssertFalse(state.transcript.contains("[00:00]"))

        await state.stopAndGenerateNotes()

        XCTAssertEqual(state.status, .completed)
        XCTAssertTrue(state.transcript.hasPrefix("[00:00] "))
        XCTAssertTrue(state.transcript.contains("\n\n[00:30] "))
        XCTAssertNil(state.warning)
    }

    @MainActor
    func testUnrecoverableChunkLeavesWarningButStillProducesNotes() async {
        let capture = FakeAudioCapture()
        let transcriber = FakeTranscriber(failuresRemaining: [FakeAudioCapture.fileName(for: 1): 5])
        let state = makeState(capture: capture, transcriber: transcriber)

        await state.startRecording()
        capture.emitChunk(index: 0, startTime: 0)
        capture.emitChunk(index: 1, startTime: 30)
        await state.stopAndGenerateNotes()

        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(state.warning, "1 of 1 failed segment(s) could not be transcribed and are missing from the transcript.")
        XCTAssertFalse(state.transcript.contains("[00:30]"))
    }

    @MainActor
    func testWhisperEngineRequiresOpenAIKey() async {
        let capture = FakeAudioCapture()
        let state = makeState(capture: capture, keys: [.anthropic: "ak-test"], transcriptionEngine: .openAIWhisper)

        await state.startRecording()

        XCTAssertEqual(state.status, .error("OpenAI API key is missing. Add it in Settings."))
        XCTAssertEqual(capture.startCount, 0)
    }

    @MainActor
    func testMissingPermissionRequestsAccess() async {
        let capture = FakeAudioCapture()
        capture.permissionGranted = false
        let state = makeState(capture: capture)

        await state.startRecording()

        XCTAssertEqual(state.status, .error(AudioCaptureError.permissionDenied.localizedDescription))
        XCTAssertTrue(state.needsScreenCapturePermission)
        XCTAssertEqual(capture.permissionRequestCount, 1)
        XCTAssertEqual(capture.startCount, 0)
    }

    @MainActor
    func testCaptureStartFailureIsReported() async {
        let capture = FakeAudioCapture()
        capture.startError = AudioCaptureError.noDisplayAvailable
        let state = makeState(capture: capture)

        await state.startRecording()

        XCTAssertEqual(state.status, .error(AudioCaptureError.noDisplayAvailable.localizedDescription))
        XCTAssertTrue(state.canStartRecording)
    }

    @MainActor
    func testClaudeEngineWithoutKeyKeepsTranscriptAndAllowsRegeneration() async throws {
        let capture = FakeAudioCapture()
        let recorder = ConfigurationRecorder()
        let state = makeState(capture: capture, keys: [.openAI: "sk-test"], noteEngine: .claude, recorder: recorder)

        await state.startRecording()
        XCTAssertNotNil(state.warning, "Recording should warn that notes need an Anthropic key")
        capture.emitChunk(index: 0, startTime: 0)
        await state.stopAndGenerateNotes()

        guard case .error(let message) = state.status else {
            return XCTFail("Expected an error, got \(state.status)")
        }
        XCTAssertTrue(message.contains("Anthropic API key is missing"))
        XCTAssertFalse(state.transcript.isEmpty)
        XCTAssertTrue(state.canRegenerateNotes)

        try state.setAPIKey("ak-new", for: .anthropic)
        XCTAssertNil(state.warning)
        await state.regenerateNotes()

        XCTAssertEqual(state.status, .completed)
        XCTAssertTrue(state.hasNotes)
        XCTAssertEqual(recorder.noteGenerators, [NoteGeneratorConfiguration(engine: .claude, apiKey: "ak-new", model: AnthropicNoteGeneratorService.defaultModel)])
    }

    @MainActor
    func testRecordingWithoutSpeechReportsError() async {
        let capture = FakeAudioCapture()
        let generator = FakeNoteGenerator()
        let state = makeState(capture: capture, generator: generator)

        await state.startRecording()
        await state.stopAndGenerateNotes()

        guard case .error(let message) = state.status else {
            return XCTFail("Expected an error, got \(state.status)")
        }
        XCTAssertTrue(message.contains("No speech was detected"))
        XCTAssertTrue(generator.requests.isEmpty)
    }

    @MainActor
    func testNoteGenerationFailureKeepsTranscriptAndPartialNotes() async {
        let capture = FakeAudioCapture()
        let generator = FakeNoteGenerator(fragments: ["# Partial"], failure: APIError.serviceError(service: "Anthropic", message: "Overloaded"))
        let state = makeState(capture: capture, generator: generator)

        await state.startRecording()
        capture.emitChunk(index: 0, startTime: 0)
        await state.stopAndGenerateNotes()

        guard case .error(let message) = state.status else {
            return XCTFail("Expected an error, got \(state.status)")
        }
        XCTAssertTrue(message.contains("Overloaded"))
        XCTAssertEqual(state.notes, "# Partial")
        XCTAssertFalse(state.transcript.isEmpty)
        XCTAssertTrue(state.canRegenerateNotes)
    }

    @MainActor
    func testSystemStoppingCaptureFinishesTheSession() async throws {
        let capture = FakeAudioCapture()
        let state = makeState(capture: capture)

        await state.startRecording()
        capture.send(.level(0.5))
        try await waitUntil { state.levelMeter.levels.last == 0.5 }
        capture.emitChunk(index: 0, startTime: 0)
        capture.send(.stoppedUnexpectedly("The user stopped the stream."))

        try await waitUntil { state.status == .completed }
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertFalse(state.transcript.isEmpty)
        XCTAssertTrue(state.warning?.contains("The user stopped the stream.") ?? false)
    }

    @MainActor
    func testStartingANewRecordingClearsThePreviousSession() async {
        let capture = FakeAudioCapture()
        let state = makeState(capture: capture)

        await state.startRecording()
        capture.emitChunk(index: 0, startTime: 0)
        await state.stopAndGenerateNotes()
        XCTAssertEqual(state.status, .completed)

        await state.startRecording()

        XCTAssertEqual(state.status, .recording)
        XCTAssertEqual(state.transcript, "")
        XCTAssertEqual(state.notes, "")
        XCTAssertNil(state.recordingEndedAt)
    }

    @MainActor
    func testSessionIsArchivedToDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LectureMindArchive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = SessionArchive(rootDirectory: root)
        let capture = FakeAudioCapture()
        let state = makeState(capture: capture, archive: archive)

        await state.startRecording()
        capture.emitChunk(index: 0, startTime: 0)
        await state.stopAndGenerateNotes()

        let folder = archive.directory(forSessionStartedAt: try XCTUnwrap(state.recordingStartedAt))
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        let notes = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertEqual(transcript, state.transcript)
        XCTAssertEqual(notes, state.notes)
    }
}
