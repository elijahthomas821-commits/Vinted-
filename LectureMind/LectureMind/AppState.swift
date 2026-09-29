import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

enum SettingsKeys {
    static let claudeModel = "claudeModel"
    static let transcriptionLanguage = "transcriptionLanguage"
    static let transcriptionEngine = "transcriptionEngine"
    static let noteEngine = "noteEngine"
}

struct TranscriberConfiguration: Equatable {
    let engine: TranscriptionEngine
    let apiKey: String?
    let language: String?
}

struct NoteGeneratorConfiguration: Equatable {
    let engine: NoteEngine
    let apiKey: String?
    let model: String
}

/// Rolling history of input levels for the live meter. Kept separate from `AppState` so the
/// ~10 Hz updates only re-render the meter, not the whole popover.
@MainActor
final class LevelMeterModel: ObservableObject {
    static let historyLength = 28

    @Published private(set) var levels = [Float](repeating: 0, count: LevelMeterModel.historyLength)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
    }

    func reset() {
        levels = [Float](repeating: 0, count: Self.historyLength)
    }
}

/// Owns the recording session: capture → chunked transcription → structured notes.
@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle
        case recording
        case transcribing
        case generatingNotes
        case completed
        case error(String)
    }

    enum PreviewContent {
        case transcript
        case notes
    }

    /// What raised the current `warning`, so resolving one problem doesn't hide another.
    private enum WarningSource {
        case notesSetup
        case transcription
        case other
    }

    typealias TranscriberFactory = (TranscriberConfiguration) -> any TranscriptionServiceProtocol
    typealias NoteGeneratorFactory = (NoteGeneratorConfiguration) -> any NoteGeneratorServiceProtocol

    nonisolated static func makeDefaultTranscriber(_ configuration: TranscriberConfiguration) -> any TranscriptionServiceProtocol {
        switch configuration.engine {
        case .appleOnDevice:
            return AppleSpeechTranscriptionService(languageCode: configuration.language)
        case .openAIWhisper:
            return OpenAIWhisperTranscriptionService(apiKey: configuration.apiKey ?? "", language: configuration.language)
        }
    }

    nonisolated static func makeDefaultNoteGenerator(_ configuration: NoteGeneratorConfiguration) -> any NoteGeneratorServiceProtocol {
        switch configuration.engine {
        case .appleIntelligence:
            return AppleIntelligenceNoteGeneratorService()
        case .claude:
            return AnthropicNoteGeneratorService(apiKey: configuration.apiKey ?? "", model: configuration.model)
        }
    }

    @Published private(set) var status: Status = .idle
    /// Timestamped transcript accumulated over the whole lecture.
    @Published private(set) var transcript = ""
    @Published private(set) var notes = ""
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingEndedAt: Date?
    /// Chunks currently being transcribed.
    @Published private(set) var pendingChunkCount = 0
    /// Progress of multi-step note generation, e.g. "Summarizing part 2 of 5…".
    @Published private(set) var notesProgress: String?
    /// Non-fatal problems worth showing without interrupting the recording.
    @Published private(set) var warning: String?
    @Published private(set) var needsScreenCapturePermission = false
    @Published private(set) var needsSpeechPermission = false
    @Published private(set) var isStarting = false

    let levelMeter = LevelMeterModel()

    private let capture: any AudioCapturing
    private let keyStore: any APIKeyStore
    private let defaults: UserDefaults
    private let archive: SessionArchive?
    private let makeTranscriber: TranscriberFactory
    private let makeNoteGenerator: NoteGeneratorFactory
    private let appleIntelligenceUnavailability: () -> String?
    private let logger = Logger(subsystem: "com.lecturemind.app", category: "AppState")

    private var transcriber: (any TranscriptionServiceProtocol)?
    private var segments: [Int: TranscriptSegment] = [:]
    private var failedChunks: [AudioChunk] = []
    private var lastTranscriptionError: String?
    private var warningSource: WarningSource?
    private var chunkPipeline: Task<Void, Never>?

    init(
        capture: any AudioCapturing = AudioCaptureManager(),
        keyStore: any APIKeyStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        archive: SessionArchive? = SessionArchive(rootDirectory: SessionArchive.defaultRootDirectory),
        makeTranscriber: @escaping TranscriberFactory = AppState.makeDefaultTranscriber,
        makeNoteGenerator: @escaping NoteGeneratorFactory = AppState.makeDefaultNoteGenerator,
        appleIntelligenceUnavailability: @escaping () -> String? = AppleIntelligenceNoteGeneratorService.unavailabilityReason
    ) {
        self.capture = capture
        self.keyStore = keyStore
        self.defaults = defaults
        self.archive = archive
        self.makeTranscriber = makeTranscriber
        self.makeNoteGenerator = makeNoteGenerator
        self.appleIntelligenceUnavailability = appleIntelligenceUnavailability
        // Chunks from a session that crashed or was force-quit are no longer useful.
        capture.removeTemporaryFiles()
    }

    // MARK: Derived state

    var isRecording: Bool { status == .recording }
    var isProcessing: Bool { status == .transcribing || status == .generatingNotes }
    var canStartRecording: Bool { !isRecording && !isProcessing && !isStarting }
    var canRegenerateNotes: Bool { !transcript.isEmpty && !isRecording && !isProcessing && !isStarting }
    var hasNotes: Bool { !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var recordedDuration: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return (recordingEndedAt ?? Date()).timeIntervalSince(recordingStartedAt)
    }

    var claudeModel: String {
        let value = defaults.string(forKey: SettingsKeys.claudeModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? AnthropicNoteGeneratorService.defaultModel : value
    }

    var transcriptionLanguage: String? {
        let value = defaults.string(forKey: SettingsKeys.transcriptionLanguage)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Free on-device engines are the default; the paid APIs are opt-in from Settings.
    var transcriptionEngine: TranscriptionEngine {
        defaults.string(forKey: SettingsKeys.transcriptionEngine).flatMap(TranscriptionEngine.init(rawValue:)) ?? .appleOnDevice
    }

    var noteEngine: NoteEngine {
        defaults.string(forKey: SettingsKeys.noteEngine).flatMap(NoteEngine.init(rawValue:)) ?? .appleIntelligence
    }

    /// `nil` when the on-device notes model is ready, otherwise why it can't be used.
    func appleIntelligenceStatus() -> String? {
        appleIntelligenceUnavailability()
    }

    /// Why the selected note engine won't be able to run, if anything is missing.
    private func notesSetupProblem() -> String? {
        switch noteEngine {
        case .claude:
            return keyStore.apiKey(for: .anthropic) == nil
                ? "Notes use Claude, but there's no Anthropic API key yet. Add it in Settings before you stop, or switch notes to Apple Intelligence."
                : nil
        case .appleIntelligence:
            return appleIntelligenceUnavailability().map {
                "Apple Intelligence can't write notes on this Mac: \($0) Switch notes to Claude in Settings before you stop."
            }
        }
    }

    // MARK: Recording

    func toggleRecording() async {
        if isRecording {
            await stopAndGenerateNotes()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        guard canStartRecording else { return }
        clearWarning()

        let engine = transcriptionEngine
        var openAIKey: String?
        if engine == .openAIWhisper {
            guard let key = keyStore.apiKey(for: .openAI) else {
                status = .error(APIError.missingAPIKey(service: OpenAIWhisperTranscriptionService.serviceName).localizedDescription)
                return
            }
            openAIKey = key
        }
        guard capture.hasScreenCapturePermission() else {
            // Shows the system prompt the first time; afterwards the user has to flip the
            // switch in System Settings and relaunch.
            capture.requestScreenCapturePermission()
            needsScreenCapturePermission = true
            status = .error(AudioCaptureError.permissionDenied.localizedDescription)
            return
        }
        needsScreenCapturePermission = false
        needsSpeechPermission = false

        isStarting = true
        defer { isStarting = false }
        resetSession()
        status = .idle

        // Permission prompts and model downloads happen before any audio is captured.
        let transcriber = makeTranscriber(TranscriberConfiguration(engine: engine, apiKey: openAIKey, language: transcriptionLanguage))
        do {
            try await transcriber.prepare()
        } catch {
            if let speechError = error as? OnDeviceTranscriptionError, speechError == .permissionDenied {
                needsSpeechPermission = true
            }
            status = .error(error.localizedDescription)
            return
        }

        let chunks: AsyncStream<AudioChunk>
        do {
            chunks = try await capture.start { [weak self] event in
                // Rebind as a constant: Swift 5.10 rejects reading the weak (var) capture
                // from inside the nested, concurrently-executing Task.
                guard let self else { return }
                Task { @MainActor in self.handle(event) }
            }
        } catch {
            if let captureError = error as? AudioCaptureError, case .permissionDenied = captureError {
                needsScreenCapturePermission = true
            }
            status = .error(error.localizedDescription)
            return
        }

        self.transcriber = transcriber
        recordingStartedAt = Date()
        status = .recording
        if let problem = notesSetupProblem() {
            setWarning(problem, source: .notesSetup)
        }

        // Chunks are transcribed one at a time, in order, while recording continues.
        chunkPipeline = Task { [weak self] in
            for await chunk in chunks {
                guard let self else { return }
                await self.transcribe(chunk)
            }
        }
    }

    func stopAndGenerateNotes() async {
        guard status == .recording else { return }
        status = .transcribing
        recordingEndedAt = Date()
        levelMeter.reset()

        await capture.stop()           // Flushes the final partial chunk and ends the chunk stream.
        await chunkPipeline?.value     // Waits for every queued chunk to be transcribed.
        chunkPipeline = nil
        await retryFailedChunks()
        transcriber = nil
        capture.removeTemporaryFiles()

        guard !transcript.isEmpty else {
            status = .error(lastTranscriptionError.map { "Transcription failed: \($0)" }
                ?? "No speech was detected. Make sure the lecture is playing through this Mac and isn't muted.")
            return
        }
        await generateNotes()
    }

    func regenerateNotes() async {
        guard canRegenerateNotes else { return }
        await generateNotes()
    }

    // MARK: Settings

    func apiKey(for kind: APIKeyKind) -> String? {
        keyStore.apiKey(for: kind)
    }

    func setAPIKey(_ value: String, for kind: APIKeyKind) throws {
        try keyStore.setAPIKey(value, for: kind)
        settingsDidChange()
    }

    /// Re-checks setup warnings after the user changes engines or keys.
    func settingsDidChange() {
        if notesSetupProblem() == nil {
            clearWarning(ifFrom: .notesSetup)
        }
    }

    func hasScreenCapturePermission() -> Bool {
        capture.hasScreenCapturePermission()
    }

    // MARK: Clipboard, export, and archive

    func text(for content: PreviewContent) -> String {
        switch content {
        case .transcript: return transcript
        case .notes: return notes
        }
    }

    @discardableResult
    func copyToClipboard(_ content: PreviewContent) -> Bool {
        let text = text(for: content)
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func export(_ content: PreviewContent) {
        let text = text(for: content)
        guard !text.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = content == .notes ? "Export Lecture Notes" : "Export Transcript"
        panel.nameFieldStringValue = content == .notes
            ? NotesFormatting.suggestedFileName(for: notes, date: recordingStartedAt ?? Date())
            : "Transcript \(NotesFormatting.dayStamp(for: recordingStartedAt ?? Date())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        // Menu bar apps aren't frontmost by default; without this the panel opens behind other windows.
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            setWarning("Couldn't export to \(url.lastPathComponent): \(error.localizedDescription)", source: .other)
        }
    }

    /// Opens the folder holding this session's auto-saved transcript and notes.
    func revealArchive() {
        guard let archive else { return }
        var folder = archive.rootDirectory
        if let recordingStartedAt {
            let sessionFolder = archive.directory(forSessionStartedAt: recordingStartedAt)
            if FileManager.default.fileExists(atPath: sessionFolder.path) {
                folder = sessionFolder
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Pipeline internals

    private func resetSession() {
        chunkPipeline?.cancel()
        chunkPipeline = nil
        transcriber = nil
        segments = [:]
        failedChunks = []
        lastTranscriptionError = nil
        transcript = ""
        notes = ""
        recordingStartedAt = nil
        recordingEndedAt = nil
        pendingChunkCount = 0
        notesProgress = nil
        levelMeter.reset()
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .level(let level):
            guard status == .recording else { return }
            levelMeter.push(level)
        case .warning(let message):
            setWarning(message, source: .other)
        case .stoppedUnexpectedly(let message):
            guard status == .recording else { return }
            setWarning("Recording was stopped by macOS (\(message)). Notes use everything captured until then.", source: .other)
            Task { await stopAndGenerateNotes() }
        }
    }

    private func transcribe(_ chunk: AudioChunk) async {
        guard let transcriber else { return }
        pendingChunkCount += 1
        defer { pendingChunkCount -= 1 }

        do {
            let text = try await transcriber.transcribe(audioFileURL: chunk.fileURL, prompt: promptContext(before: chunk.index))
            record(text, for: chunk)
            try? FileManager.default.removeItem(at: chunk.fileURL)
        } catch {
            // Keep the audio and try again after recording stops, so a network blip mid-lecture
            // doesn't leave a hole in the notes.
            failedChunks.append(chunk)
            lastTranscriptionError = error.localizedDescription
            logger.error("Chunk \(chunk.index) failed: \(error.localizedDescription, privacy: .public)")
            setWarning(
                "Couldn't transcribe the segment at \(TimeFormatting.clock(chunk.startTime)) (\(error.localizedDescription)). It will be retried when you stop.",
                source: .transcription
            )
        }
    }

    private func retryFailedChunks() async {
        guard let transcriber, !failedChunks.isEmpty else { return }
        let chunks = failedChunks.sorted { $0.index < $1.index }
        failedChunks = []

        var unrecoverable = 0
        for chunk in chunks {
            do {
                let text = try await transcriber.transcribe(audioFileURL: chunk.fileURL, prompt: promptContext(before: chunk.index))
                record(text, for: chunk)
            } catch {
                unrecoverable += 1
                lastTranscriptionError = error.localizedDescription
            }
        }
        if unrecoverable == 0 {
            clearWarning(ifFrom: .transcription)
        } else {
            setWarning(
                "\(unrecoverable) of \(chunks.count) failed segment(s) could not be transcribed and are missing from the transcript.",
                source: .transcription
            )
        }
    }

    private func setWarning(_ message: String, source: WarningSource) {
        warning = message
        warningSource = source
    }

    private func clearWarning(ifFrom source: WarningSource? = nil) {
        guard source == nil || warningSource == source else { return }
        warning = nil
        warningSource = nil
    }

    private func promptContext(before index: Int) -> String? {
        let previous = segments.values
            .filter { $0.index < index }
            .max { $0.index < $1.index }
        return TranscriptFormatter.promptContext(from: previous?.text)
    }

    private func record(_ text: String, for chunk: AudioChunk) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments[chunk.index] = TranscriptSegment(index: chunk.index, startTime: chunk.startTime, text: trimmed)
        transcript = TranscriptFormatter.render(Array(segments.values))

        if let archive, let recordingStartedAt {
            do {
                try archive.saveTranscript(transcript, sessionStartedAt: recordingStartedAt)
            } catch {
                logger.error("Transcript autosave failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func generateNotes() async {
        let engine = noteEngine
        var anthropicKey: String?
        switch engine {
        case .claude:
            guard let key = keyStore.apiKey(for: .anthropic) else {
                status = .error("Anthropic API key is missing. Add it in Settings (or switch notes to Apple Intelligence), then choose Regenerate Notes. Your transcript has been kept.")
                return
            }
            anthropicKey = key
        case .appleIntelligence:
            if let reason = appleIntelligenceUnavailability() {
                status = .error("\(OnDeviceNotesError.unavailable(reason).localizedDescription) Your transcript has been kept.")
                return
            }
        }

        status = .generatingNotes
        notes = ""
        notesProgress = nil
        defer { notesProgress = nil }
        let generator = makeNoteGenerator(NoteGeneratorConfiguration(engine: engine, apiKey: anthropicKey, model: claudeModel))
        let request = NoteRequest(transcript: transcript, recordedAt: recordingStartedAt ?? Date(), duration: recordedDuration)

        var buffer = ""
        var lastPublished = Date.distantPast
        do {
            for try await update in generator.generateNotes(for: request) {
                switch update {
                case .text(let fragment):
                    buffer += fragment
                    // Publishing every token would re-render the preview dozens of times a second.
                    if Date().timeIntervalSince(lastPublished) >= 0.1 {
                        notes = buffer
                        lastPublished = Date()
                    }
                case .progress(let message):
                    notesProgress = message
                }
            }
            let finalNotes = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalNotes.isEmpty else {
                throw APIError.emptyResult(service: engine == .claude ? AnthropicNoteGeneratorService.serviceName : AppleIntelligenceNoteGeneratorService.serviceName)
            }
            notes = finalNotes
            if let archive, let recordingStartedAt {
                do {
                    try archive.saveNotes(finalNotes, sessionStartedAt: recordingStartedAt)
                } catch {
                    logger.error("Notes autosave failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            status = .completed
        } catch {
            notes = buffer
            status = .error("Couldn't generate notes: \(error.localizedDescription) Your transcript has been kept; choose Regenerate Notes to try again.")
        }
    }
}
