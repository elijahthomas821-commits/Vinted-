import XCTest
@testable import LectureMind

final class FormattingTests: XCTestCase {
    func testClockFormatting() {
        XCTAssertEqual(TimeFormatting.clock(0), "00:00")
        XCTAssertEqual(TimeFormatting.clock(65.9), "01:05")
        XCTAssertEqual(TimeFormatting.clock(3_725), "1:02:05")
        XCTAssertEqual(TimeFormatting.clock(-5), "00:00")
    }

    func testTranscriptRendersSegmentsInRecordingOrder() {
        let transcript = TranscriptFormatter.render([
            TranscriptSegment(index: 2, startTime: 60, text: "Third."),
            TranscriptSegment(index: 0, startTime: 0, text: "First."),
            TranscriptSegment(index: 1, startTime: 30, text: "Second."),
        ])
        XCTAssertEqual(transcript, "[00:00] First.\n\n[00:30] Second.\n\n[01:00] Third.")
    }

    func testPromptContext() {
        XCTAssertNil(TranscriptFormatter.promptContext(from: nil))
        XCTAssertNil(TranscriptFormatter.promptContext(from: "   \n"))
        XCTAssertEqual(TranscriptFormatter.promptContext(from: " short text "), "short text")

        let words = (1...400).map { "word\($0)" }.joined(separator: " ")
        let context = TranscriptFormatter.promptContext(from: words, maxCharacters: 100)
        XCTAssertNotNil(context)
        XCTAssertLessThanOrEqual(context?.count ?? 0, 100)
        XCTAssertTrue(words.hasSuffix(context ?? "-"))
        XCTAssertTrue(context?.hasPrefix("word") ?? false, "context should start on a word boundary")
    }

    func testNotesTitle() {
        XCTAssertEqual(NotesFormatting.title(from: "# Intro to Algorithms\n\n## Executive Summary"), "Intro to Algorithms")
        XCTAssertEqual(NotesFormatting.title(from: "\n  # [Graph Theory]  \n"), "Graph Theory")
        XCTAssertNil(NotesFormatting.title(from: "## Executive Summary only"))
        XCTAssertNil(NotesFormatting.title(from: "#"))
    }

    func testSuggestedFileNameIsFilesystemSafe() {
        XCTAssertEqual(NotesFormatting.suggestedFileName(for: "# Cells: Structure/Function?\nBody"), "Cells Structure Function.md")
        XCTAssertEqual(NotesFormatting.suggestedFileName(for: "# ..hidden"), "hidden.md")

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 29
        components.hour = 12
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(NotesFormatting.suggestedFileName(for: "No heading", date: date), "Lecture Notes 2026-09-29.md")
        XCTAssertEqual(NotesFormatting.suggestedFileName(for: "# ///", date: date), "Lecture Notes 2026-09-29.md")
    }

    func testMarkdownBlocksCoverNoteStructure() {
        let markdown = """
        # Photosynthesis

        ## Key Concepts & Definitions
        - **Chlorophyll** — pigment that absorbs light.
          - Found in chloroplasts
        * Second bullet
        1. First step
        2) Second step
        - [ ] Read chapter 4
        - [x] Submit lab
        > Exam next week
        ---
        **[03:10] Light reactions**
        ```
        6CO2 + 6H2O
        ```
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .heading(level: 1, text: "Photosynthesis"),
            .heading(level: 2, text: "Key Concepts & Definitions"),
            .bullet(depth: 0, text: "**Chlorophyll** — pigment that absorbs light."),
            .bullet(depth: 1, text: "Found in chloroplasts"),
            .bullet(depth: 0, text: "Second bullet"),
            .numbered(depth: 0, marker: "1.", text: "First step"),
            .numbered(depth: 0, marker: "2.", text: "Second step"),
            .task(depth: 0, text: "Read chapter 4", isDone: false),
            .task(depth: 0, text: "Submit lab", isDone: true),
            .quote("Exam next week"),
            .rule,
            .paragraph("**[03:10] Light reactions**"),
            .code("6CO2 + 6H2O"),
        ])
    }

    func testMarkdownHashWithoutSpaceIsParagraph() {
        XCTAssertEqual(MarkdownBlock.parse("#hashtag"), [.paragraph("#hashtag")])
    }
}
