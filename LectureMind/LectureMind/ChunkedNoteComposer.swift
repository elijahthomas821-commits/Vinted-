import Foundation

/// Structured notes for one slice of the lecture.
struct SectionSummary: Equatable, Sendable {
    struct Definition: Equatable, Sendable {
        let term: String
        let meaning: String
    }

    var heading: String
    var keyPoints: [String]
    var definitions: [Definition]
    var actionItems: [String]
}

struct LectureOverview: Equatable, Sendable {
    var title: String
    var summary: String
}

enum SummarizerError: Error, Equatable {
    /// The excerpt didn't fit the model's context window; the composer retries with smaller pieces.
    case inputTooLong
    /// The model declined to summarize this excerpt (for example, a safety guardrail).
    case declined
}

/// A small language model that can summarize short excerpts, such as the on-device Apple
/// Intelligence model. Implementations only ever see text that fits their context window.
protocol LectureSummarizer: Sendable {
    func summarizeSection(_ excerpt: String) async throws -> SectionSummary
    func overview(of outline: String) async throws -> LectureOverview
}

/// Builds the standard five-section notes from a model with a small context window: each
/// transcript chunk is summarized on its own, then a short outline of those summaries is
/// turned into the title and executive summary. Lecture length is therefore unbounded.
struct ChunkedNoteComposer: Sendable {
    let summarizer: any LectureSummarizer
    var maxChunkCharacters = 4_000
    var maxOutlineCharacters = 5_000
    /// Excerpts shorter than this are not split further after an `inputTooLong` error.
    var minimumChunkCharacters = 500

    func compose(_ request: NoteRequest, progress: (String) -> Void = { _ in }) async throws -> String {
        let chunks = TranscriptChunker.chunks(from: request.transcript, maxCharacters: maxChunkCharacters)
        guard !chunks.isEmpty else { throw APIError.emptyResult(service: "Apple Intelligence") }

        var sections: [(timestamp: String?, summary: SectionSummary)] = []
        for (position, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress("Summarizing part \(position + 1) of \(chunks.count)…")
            let summary = try await summarize(chunk.text, fallbackHeading: "Part \(position + 1)")
            sections.append((chunk.timestamp, summary))
        }

        try Task.checkCancellation()
        progress("Writing the executive summary…")
        let outline = Self.outline(of: sections.map(\.summary), maxCharacters: maxOutlineCharacters)
        let overview: LectureOverview
        do {
            overview = try await summarizer.overview(of: outline)
        } catch SummarizerError.declined {
            overview = LectureOverview(title: sections.first?.summary.heading ?? "Lecture Notes", summary: "")
        }
        return Self.render(overview: overview, sections: sections)
    }

    /// Summarizes `excerpt`, halving it whenever it overflows the model's context window.
    private func summarize(_ excerpt: String, fallbackHeading: String) async throws -> SectionSummary {
        do {
            return try await summarizer.summarizeSection(excerpt)
        } catch SummarizerError.inputTooLong where excerpt.count > minimumChunkCharacters {
            let halves = TranscriptChunker.splitInHalf(excerpt)
            let first = try await summarize(halves.0, fallbackHeading: fallbackHeading)
            let second = try await summarize(halves.1, fallbackHeading: fallbackHeading)
            return SectionSummary(
                heading: first.heading,
                keyPoints: first.keyPoints + second.keyPoints,
                definitions: first.definitions + second.definitions,
                actionItems: first.actionItems + second.actionItems
            )
        } catch SummarizerError.declined {
            return SectionSummary(
                heading: fallbackHeading,
                keyPoints: ["(This part couldn't be summarized on-device; see the transcript.)"],
                definitions: [],
                actionItems: []
            )
        }
    }

    static func outline(of summaries: [SectionSummary], maxCharacters: Int) -> String {
        var lines: [String] = []
        var length = 0
        for summary in summaries {
            let points = summary.keyPoints.map(clean).filter { !$0.isEmpty }.prefix(3)
            let block = ([clean(summary.heading)] + points.map { "- \($0)" }).joined(separator: "\n")
            guard length + block.count <= maxCharacters else { break }
            lines.append(block)
            length += block.count + 2
        }
        return lines.joined(separator: "\n\n")
    }

    static func render(overview: LectureOverview, sections: [(timestamp: String?, summary: SectionSummary)]) -> String {
        let title = clean(overview.title).isEmpty ? "Lecture Notes" : clean(overview.title)
        var markdown = "# \(title)\n\n## Executive Summary\n"
        let summary = overview.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        markdown += summary.isEmpty ? "_No summary available._\n" : "\(summary)\n"

        markdown += "\n## Key Concepts & Definitions\n"
        var seenTerms = Set<String>()
        let definitions = sections.flatMap(\.summary.definitions).filter { definition in
            let key = clean(definition.term).lowercased()
            return !key.isEmpty && !clean(definition.meaning).isEmpty && seenTerms.insert(key).inserted
        }
        if definitions.isEmpty {
            markdown += "- None identified in this lecture.\n"
        } else {
            for definition in definitions {
                markdown += "- **\(clean(definition.term))** — \(clean(definition.meaning))\n"
            }
        }

        markdown += "\n## Detailed Lecture Breakdown (Bulleted)\n"
        for (timestamp, section) in sections {
            let heading = clean(section.heading).isEmpty ? "Section" : clean(section.heading)
            markdown += "\n**\(timestamp.map { "[\($0)] " } ?? "")\(heading)**\n"
            for point in section.keyPoints.map(clean) where !point.isEmpty {
                markdown += "- \(point)\n"
            }
        }

        markdown += "\n## Action Items, Assignments & Key Dates\n"
        var seenItems = Set<String>()
        let actionItems = sections.flatMap(\.summary.actionItems).map(clean).filter {
            !$0.isEmpty && seenItems.insert($0.lowercased()).inserted
        }
        if actionItems.isEmpty {
            markdown += "- None mentioned in this lecture.\n"
        } else {
            for item in actionItems {
                markdown += "- [ ] \(item)\n"
            }
        }
        return markdown
    }

    /// Trims whitespace and any list marker the model added itself.
    private static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["- [ ] ", "- ", "* ", "• "] where result.hasPrefix(marker) {
            result = String(result.dropFirst(marker.count))
            break
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriptChunker {
    struct Chunk: Equatable {
        /// Timestamp of the chunk's first segment, e.g. `"03:30"`.
        let timestamp: String?
        let text: String
    }

    /// Groups the timestamped paragraphs produced by `TranscriptFormatter.render` into chunks of
    /// at most `maxCharacters`, keeping each chunk's starting timestamp. Timestamps are removed
    /// from the text itself so the model doesn't echo them into bullet points.
    static func chunks(from transcript: String, maxCharacters: Int) -> [Chunk] {
        var chunks: [Chunk] = []
        var currentText = ""
        var currentTimestamp: String?

        func flush() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chunks.append(Chunk(timestamp: currentTimestamp, text: text))
            }
            currentText = ""
            currentTimestamp = nil
        }

        for paragraph in transcript.components(separatedBy: "\n\n") {
            let (timestamp, body) = splitTimestamp(paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !body.isEmpty else { continue }
            for piece in split(body, maxCharacters: maxCharacters) {
                if !currentText.isEmpty && currentText.count + 1 + piece.count > maxCharacters {
                    flush()
                }
                if currentText.isEmpty {
                    currentTimestamp = timestamp
                }
                currentText += currentText.isEmpty ? piece : " \(piece)"
            }
        }
        flush()
        return chunks
    }

    /// Separates a leading `[mm:ss]` or `[h:mm:ss]` stamp from the paragraph text.
    static func splitTimestamp(_ paragraph: String) -> (String?, String) {
        guard paragraph.hasPrefix("["), let close = paragraph.firstIndex(of: "]") else {
            return (nil, paragraph)
        }
        let stamp = String(paragraph[paragraph.index(after: paragraph.startIndex)..<close])
        guard !stamp.isEmpty, stamp.allSatisfy({ $0.isNumber || $0 == ":" }) else {
            return (nil, paragraph)
        }
        return (stamp, paragraph[paragraph.index(after: close)...].trimmingCharacters(in: .whitespaces))
    }

    /// Splits text longer than `maxCharacters` at word boundaries.
    static func split(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters, maxCharacters > 0 else { return [text] }
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if !current.isEmpty && current.count + 1 + word.count > maxCharacters {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " \(word)"
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    /// Splits text into two halves at the word boundary closest to the middle.
    static func splitInHalf(_ text: String) -> (String, String) {
        let words = text.split(separator: " ")
        guard words.count > 1 else {
            let middle = text.index(text.startIndex, offsetBy: text.count / 2)
            return (String(text[..<middle]), String(text[middle...]))
        }
        let half = words.count / 2
        return (words[..<half].joined(separator: " "), words[half...].joined(separator: " "))
    }
}
