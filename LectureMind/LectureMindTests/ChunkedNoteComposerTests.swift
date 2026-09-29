import XCTest
@testable import LectureMind

final class ChunkedNoteComposerTests: XCTestCase {
    /// Summarizes each excerpt as its first word and records what it was asked.
    private final class FakeSummarizer: LectureSummarizer, @unchecked Sendable {
        private let lock = NSLock()
        private var excerpts: [String] = []
        private var outlines: [String] = []
        var tooLongAbove = Int.max
        var declineContaining: String?

        var sectionExcerpts: [String] { lock.withLock { excerpts } }
        var overviewOutlines: [String] { lock.withLock { outlines } }

        func summarizeSection(_ excerpt: String) async throws -> SectionSummary {
            lock.withLock { excerpts.append(excerpt) }
            if excerpt.count > tooLongAbove { throw SummarizerError.inputTooLong }
            if let declineContaining, excerpt.contains(declineContaining) { throw SummarizerError.declined }
            let firstWord = excerpt.split(separator: " ").first.map(String.init) ?? "?"
            return SectionSummary(
                heading: "About \(firstWord)",
                keyPoints: ["- \(firstWord) matters", "  "],
                definitions: [.init(term: firstWord.capitalized, meaning: "The word \(firstWord)."), .init(term: "Shared", meaning: "Appears everywhere.")],
                actionItems: firstWord == "homework" ? ["Read chapter 2 by Friday", "- [ ] read chapter 2 by friday"] : []
            )
        }

        func overview(of outline: String) async throws -> LectureOverview {
            lock.withLock { outlines.append(outline) }
            return LectureOverview(title: "  Test Lecture ", summary: "It covered things.")
        }
    }

    private func request(_ transcript: String) -> NoteRequest {
        NoteRequest(transcript: transcript, recordedAt: Date(timeIntervalSince1970: 0), duration: 120)
    }

    func testComposesAllSectionsFromChunkSummaries() async throws {
        let summarizer = FakeSummarizer()
        var composer = ChunkedNoteComposer(summarizer: summarizer)
        composer.maxChunkCharacters = 40
        var progress: [String] = []

        let notes = try await composer.compose(
            request("[00:00] alpha one two three four five six\n\n[00:30] homework is due soon okay\n\n[01:00] gamma ends it"),
            progress: { progress.append($0) }
        )

        XCTAssertEqual(summarizer.sectionExcerpts, [
            "alpha one two three four five six",
            "homework is due soon okay gamma ends it",
        ])
        XCTAssertEqual(progress, ["Summarizing part 1 of 2…", "Summarizing part 2 of 2…", "Writing the executive summary…"])
        XCTAssertEqual(notes, """
        # Test Lecture

        ## Executive Summary
        It covered things.

        ## Key Concepts & Definitions
        - **Alpha** — The word alpha.
        - **Shared** — Appears everywhere.
        - **Homework** — The word homework.

        ## Detailed Lecture Breakdown (Bulleted)

        **[00:00] About alpha**
        - alpha matters

        **[00:30] About homework**
        - homework matters

        ## Action Items, Assignments & Key Dates
        - [ ] Read chapter 2 by Friday

        """)
        XCTAssertEqual(summarizer.overviewOutlines, ["About alpha\n- alpha matters\n\nAbout homework\n- homework matters"])
    }

    func testOverflowingExcerptIsSplitAndRetried() async throws {
        let summarizer = FakeSummarizer()
        summarizer.tooLongAbove = 30
        var composer = ChunkedNoteComposer(summarizer: summarizer)
        composer.maxChunkCharacters = 1_000
        composer.minimumChunkCharacters = 10

        let notes = try await composer.compose(request("[00:00] alpha beta gamma delta epsilon zeta eta theta"))

        // The excerpt overflows once and is retried as two halves.
        XCTAssertEqual(summarizer.sectionExcerpts, [
            "alpha beta gamma delta epsilon zeta eta theta",
            "alpha beta gamma delta",
            "epsilon zeta eta theta",
        ])
        XCTAssertTrue(notes.contains("**[00:00] About alpha**\n- alpha matters\n- epsilon matters\n"))
    }

    func testDeclinedExcerptBecomesPlaceholderInsteadOfFailing() async throws {
        let summarizer = FakeSummarizer()
        summarizer.declineContaining = "sensitive"
        var composer = ChunkedNoteComposer(summarizer: summarizer)
        composer.maxChunkCharacters = 20

        let notes = try await composer.compose(request("[00:00] fine content here\n\n[00:30] sensitive stuff"))

        XCTAssertTrue(notes.contains("**[00:30] Part 2**\n- (This part couldn't be summarized on-device; see the transcript.)"))
        XCTAssertTrue(notes.contains("**[00:00] About fine**"))
    }

    func testEmptyTranscriptThrows() async {
        let composer = ChunkedNoteComposer(summarizer: FakeSummarizer())
        do {
            _ = try await composer.compose(request("  \n\n "))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .emptyResult(service: "Apple Intelligence"))
        }
    }

    func testNoActionItemsOrDefinitionsSaysSo() {
        let markdown = ChunkedNoteComposer.render(
            overview: LectureOverview(title: "", summary: ""),
            sections: [(timestamp: nil, summary: SectionSummary(heading: "Intro", keyPoints: ["Point"], definitions: [], actionItems: []))]
        )
        XCTAssertTrue(markdown.hasPrefix("# Lecture Notes\n\n## Executive Summary\n_No summary available._\n"))
        XCTAssertTrue(markdown.contains("## Key Concepts & Definitions\n- None identified in this lecture.\n"))
        XCTAssertTrue(markdown.contains("\n**Intro**\n- Point\n"))
        XCTAssertTrue(markdown.hasSuffix("## Action Items, Assignments & Key Dates\n- None mentioned in this lecture.\n"))
    }

    func testChunkerSplitsLongParagraphsAtWords() {
        let chunks = TranscriptChunker.chunks(from: "[1:02:03] one two three four five", maxCharacters: 9)
        XCTAssertEqual(chunks, [
            .init(timestamp: "1:02:03", text: "one two"),
            .init(timestamp: "1:02:03", text: "three"),
            .init(timestamp: "1:02:03", text: "four five"),
        ])
    }

    func testTimestampParsing() {
        XCTAssertEqual(TranscriptChunker.splitTimestamp("[03:30] Hello").0, "03:30")
        XCTAssertEqual(TranscriptChunker.splitTimestamp("[03:30] Hello").1, "Hello")
        XCTAssertNil(TranscriptChunker.splitTimestamp("[Music] Hello").0)
        XCTAssertNil(TranscriptChunker.splitTimestamp("No stamp").0)
    }
}
