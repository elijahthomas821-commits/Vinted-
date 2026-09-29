import AVFoundation
import Foundation
import OSLog
import Speech

enum OnDeviceTranscriptionError: LocalizedError, Equatable {
    case permissionDenied
    case languageUnsupported(String)
    case recognizerUnavailable
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "LectureMind needs Speech Recognition permission for free on-device transcription. Allow it in System Settings › Privacy & Security › Speech Recognition, or switch transcription to OpenAI Whisper in Settings."
        case .languageUnsupported(let identifier):
            return "Apple speech recognition doesn't support the language “\(identifier)”. Change the lecture language in Settings."
        case .recognizerUnavailable:
            return "Apple speech recognition is unavailable right now. Check that Dictation is enabled in System Settings › Keyboard."
        case .recognitionFailed(let details):
            return "Apple speech recognition failed: \(details)"
        }
    }
}

/// Free transcription with Apple's speech recognition. On macOS 26 it uses the long-form
/// `SpeechTranscriber` model, which runs entirely on-device. Elsewhere, or if that model fails,
/// it falls back to `SFSpeechRecognizer`, which is on-device when the Mac supports it.
actor AppleSpeechTranscriptionService: TranscriptionServiceProtocol {
    static let serviceName = "Apple Speech"

    private let locale: Locale
    private let logger = Logger(subsystem: "com.lecturemind.app", category: "AppleSpeech")
    /// Set once the macOS 26 `SpeechTranscriber` model is installed for `locale`.
    private var transcriberLocale: Locale?
    private var isPrepared = false

    init(languageCode: String?) {
        let code = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        locale = code.isEmpty ? .current : Locale(identifier: code)
    }

    /// Downloads the on-device model if needed, or asks for Speech Recognition permission when
    /// the older recognizer will be used.
    func prepare() async throws {
        guard !isPrepared else { return }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            do {
                transcriberLocale = try await ModernSpeech.prepare(locale: locale)
            } catch {
                logger.notice("SpeechTranscriber unavailable, using SFSpeechRecognizer: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        if transcriberLocale == nil {
            try await LegacySpeech.authorize()
            _ = try LegacySpeech.recognizer(for: locale)
        }
        isPrepared = true
    }

    func transcribe(audioFileURL: URL, prompt: String?) async throws -> String {
        try await prepare()
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let transcriberLocale {
            do {
                return try await ModernSpeech.transcribe(url: audioFileURL, locale: transcriberLocale)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("SpeechTranscriber failed, falling back: \(error.localizedDescription, privacy: .public)")
                self.transcriberLocale = nil
                try await LegacySpeech.authorize()
            }
        }
        #endif
        return try await LegacySpeech.transcribe(url: audioFileURL, locale: locale)
    }
}

// MARK: - SFSpeechRecognizer (macOS 14+)

private enum LegacySpeech {
    static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else { throw OnDeviceTranscriptionError.permissionDenied }
    }

    static func recognizer(for locale: Locale) throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw OnDeviceTranscriptionError.languageUnsupported(locale.identifier)
        }
        guard recognizer.isAvailable else { throw OnDeviceTranscriptionError.recognizerUnavailable }
        return recognizer
    }

    static func transcribe(url: URL, locale: Locale) async throws -> String {
        let recognizer = try recognizer(for: locale)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation

        let recognition = Recognition(recognizer: recognizer)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                recognition.start(request, continuation: continuation)
            }
        } onCancel: {
            recognition.cancel()
        }
    }

    /// Bridges the callback-based recognition task to async/await, resuming exactly once.
    private final class Recognition: @unchecked Sendable {
        private let lock = NSLock()
        private let recognizer: SFSpeechRecognizer
        private var task: SFSpeechRecognitionTask?
        private var continuation: CheckedContinuation<String, Error>?

        init(recognizer: SFSpeechRecognizer) {
            self.recognizer = recognizer
        }

        func start(_ request: SFSpeechURLRecognitionRequest, continuation: CheckedContinuation<String, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let task = recognizer.recognitionTask(with: request) { [self] result, error in
                if let result, result.isFinal {
                    finish(.success(result.bestTranscription.formattedString))
                } else if let error {
                    // "No speech detected" just means a quiet segment.
                    let nsError = error as NSError
                    finish(nsError.code == 1110 ? .success("") : .failure(OnDeviceTranscriptionError.recognitionFailed(error.localizedDescription)))
                }
            }
            lock.lock()
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let task = task
            lock.unlock()
            task?.cancel()
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<String, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}

// MARK: - SpeechTranscriber (macOS 26+)

#if compiler(>=6.2)
@available(macOS 26.0, *)
private enum ModernSpeech {
    /// Resolves the closest supported locale and installs its model if it isn't on disk yet.
    static func prepare(locale: Locale) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw OnDeviceTranscriptionError.languageUnsupported(locale.identifier)
        }
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale: supported)]) {
            try await installation.downloadAndInstall()
        }
        return supported
    }

    static func transcribe(url: URL, locale: Locale) async throws -> String {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let phrases = try transcriber.results.reduce(into: [String]()) { collected, result in
            collected.append(String(result.text.characters))
        }
        let file = try AVAudioFile(forReading: url)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }
}
#endif
