import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Converts a recorded audio file into text.
protocol TranscriptionServiceProtocol: Sendable {
    /// Transcribes one audio file. `prompt` carries the tail of the preceding transcript so
    /// spelling and terminology stay consistent across chunk boundaries.
    func transcribe(audioFileURL: URL, prompt: String?) async throws -> String
}

enum TranscriptionError: LocalizedError, Equatable {
    case unreadableAudio(String)
    case fileTooLarge(bytes: Int)
    case localEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let details):
            return "Could not read the recorded audio: \(details)"
        case .fileTooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "The audio chunk (\(size)) exceeds Whisper's 25 MB upload limit."
        case .localEngineUnavailable:
            return "Local transcription (WhisperKit) is not included in this build."
        }
    }
}

// MARK: - OpenAI Whisper

/// Transcribes audio with OpenAI's hosted Whisper model.
/// API reference: https://platform.openai.com/docs/api-reference/audio/createTranscription
struct OpenAIWhisperTranscriptionService: TranscriptionServiceProtocol {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let maxUploadBytes = 25 * 1024 * 1024
    static let serviceName = "OpenAI"

    let apiKey: String
    var model = "whisper-1"
    /// ISO-639-1 code such as `en`. `nil` lets Whisper auto-detect the language.
    var language: String?
    var session: URLSession = .shared
    var retryPolicy = RetryPolicy()

    func transcribe(audioFileURL: URL, prompt: String?) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw APIError.missingAPIKey(service: Self.serviceName)
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            throw TranscriptionError.unreadableAudio(error.localizedDescription)
        }
        guard audioData.count <= Self.maxUploadBytes else {
            throw TranscriptionError.fileTooLarge(bytes: audioData.count)
        }

        let request = makeRequest(apiKey: key, audioData: audioData, fileName: audioFileURL.lastPathComponent, prompt: prompt)
        return try await retryPolicy.run {
            let data = try await HTTPClient.send(request, session: session, service: Self.serviceName)
            return try Self.parseTranscript(from: data)
        }
    }

    func makeRequest(apiKey: String, audioData: Data, fileName: String, prompt: String?) -> URLRequest {
        var form = MultipartFormData()
        form.addField(name: "model", value: model)
        form.addField(name: "response_format", value: "json")
        form.addField(name: "temperature", value: "0")
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            form.addField(name: "language", value: language.lowercased())
        }
        if let prompt, !prompt.isEmpty {
            form.addField(name: "prompt", value: prompt)
        }
        form.addFile(name: "file", fileName: fileName, mimeType: Self.mimeType(forFileName: fileName), data: audioData)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.encoded()
        return request
    }

    static func parseTranscript(from data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        do {
            return try JSONDecoder().decode(Response.self, from: data).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw APIError.decodingFailed(service: serviceName, details: error.localizedDescription)
        }
    }

    static func mimeType(forFileName fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "mp4": return "audio/mp4"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Offline fallback architecture

/// Placeholder for fully offline transcription with WhisperKit
/// (https://github.com/argmaxinc/WhisperKit).
///
/// To enable it, add the WhisperKit package to the LectureMind target, load a model once
/// (e.g. `try await WhisperKit(WhisperKitConfig(model: modelName))`), keep the pipeline in
/// an actor, and return the joined `text` of `transcribe(audioPath:)` here. The 16 kHz mono
/// WAV chunks produced by `AudioCaptureManager` are already in WhisperKit's native format.
struct LocalWhisperKitTranscriptionService: TranscriptionServiceProtocol {
    var modelName = "base.en"

    func transcribe(audioFileURL: URL, prompt: String?) async throws -> String {
        throw TranscriptionError.localEngineUnavailable
    }
}

/// Tries `primary` first and falls back to `fallback` when it fails, e.g. a local engine
/// first with the hosted API as a backup, or the reverse for offline resilience.
struct FallbackTranscriptionService: TranscriptionServiceProtocol {
    let primary: any TranscriptionServiceProtocol
    let fallback: any TranscriptionServiceProtocol

    func transcribe(audioFileURL: URL, prompt: String?) async throws -> String {
        do {
            return try await primary.transcribe(audioFileURL: audioFileURL, prompt: prompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch let primaryError {
            do {
                return try await fallback.transcribe(audioFileURL: audioFileURL, prompt: prompt)
            } catch TranscriptionError.localEngineUnavailable {
                // An unavailable fallback shouldn't mask the real failure.
                throw primaryError
            }
        }
    }
}
