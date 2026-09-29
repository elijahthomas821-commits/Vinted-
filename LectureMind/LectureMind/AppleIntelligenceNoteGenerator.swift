import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum OnDeviceNotesError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Apple Intelligence can't write notes on this Mac: \(reason) You can switch notes to Claude in Settings."
        }
    }
}

/// Free, private note generation with the on-device Apple Intelligence model (macOS 26+).
/// The model's context window is small, so `ChunkedNoteComposer` summarizes the transcript
/// piece by piece and assembles the standard note structure.
struct AppleIntelligenceNoteGeneratorService: NoteGeneratorServiceProtocol {
    static let serviceName = "Apple Intelligence"

    /// `nil` when the on-device model can be used, otherwise a user-facing reason.
    static func unavailabilityReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelSummarizer.unavailabilityReason()
        }
        return "it requires macOS 26 or later."
        #else
        return "this copy of LectureMind was built without Apple Intelligence support (Xcode 26 or later is required)."
        #endif
    }

    func generateNotes(for request: NoteRequest) -> AsyncThrowingStream<NoteGenerationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let markdown = try await Self.compose(request) { continuation.yield(.progress($0)) }
                    continuation.yield(.text(markdown))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func compose(_ request: NoteRequest, progress: (String) -> Void) async throws -> String {
        if let reason = unavailabilityReason() {
            throw OnDeviceNotesError.unavailable(reason)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let composer = ChunkedNoteComposer(summarizer: FoundationModelSummarizer())
            return try await composer.compose(request, progress: progress)
        }
        #endif
        throw OnDeviceNotesError.unavailable("it requires macOS 26 or later.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct FoundationModelSummarizer: LectureSummarizer {
    static func unavailabilityReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "this Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "the Apple Intelligence model is still downloading. Try again in a few minutes."
        case .unavailable:
            return "the on-device model is currently unavailable."
        @unknown default:
            return "the on-device model is currently unavailable."
        }
    }

    private static let sectionInstructions = """
    You are an expert academic note-taker. You receive one excerpt of an automatically \
    transcribed university lecture, which may contain recognition errors. Write accurate, concise \
    study notes for this excerpt only. Fix obvious transcription errors from context, never invent \
    facts, and leave lists empty when nothing applies.
    """

    private static let overviewInstructions = """
    You are an expert academic note-taker. You receive an outline of a lecture made of section \
    headings and key points. Name the lecture and summarize it for a student.
    """

    func summarizeSection(_ excerpt: String) async throws -> SectionSummary {
        let session = LanguageModelSession(instructions: Self.sectionInstructions)
        do {
            let response = try await session.respond(
                to: "Lecture transcript excerpt:\n\n\(excerpt)",
                generating: GeneratedSection.self
            )
            let section = response.content
            return SectionSummary(
                heading: section.heading,
                keyPoints: section.keyPoints,
                definitions: section.definitions.map { .init(term: $0.term, meaning: $0.meaning) },
                actionItems: section.actionItems
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    func overview(of outline: String) async throws -> LectureOverview {
        let session = LanguageModelSession(instructions: Self.overviewInstructions)
        do {
            let response = try await session.respond(
                to: "Lecture outline:\n\n\(outline)",
                generating: GeneratedOverview.self
            )
            return LectureOverview(title: response.content.title, summary: response.content.summary)
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    private static func map(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .exceededContextWindowSize:
            return SummarizerError.inputTooLong
        case .guardrailViolation:
            return SummarizerError.declined
        default:
            return error
        }
    }
}

@available(macOS 26.0, *)
@Generable
struct GeneratedSection {
    @Guide(description: "A short title of 3 to 8 words for the topic of this excerpt")
    var heading: String

    @Guide(description: "The important points of this excerpt as concise, self-contained bullet points, in the order they were made")
    var keyPoints: [String]

    @Guide(description: "Terms that the lecturer defined or explained in this excerpt; empty if none")
    var definitions: [GeneratedDefinition]

    @Guide(description: "Assignments, readings, exams, deadlines or other tasks mentioned in this excerpt, with dates if stated; empty if none")
    var actionItems: [String]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedDefinition {
    @Guide(description: "The term being defined")
    var term: String

    @Guide(description: "A one-sentence definition as used in the lecture")
    var meaning: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedOverview {
    @Guide(description: "The lecture's title or main topic, at most 10 words")
    var title: String

    @Guide(description: "An executive summary of 3 to 5 sentences covering the lecture's purpose, main ideas and conclusions")
    var summary: String
}
#endif
