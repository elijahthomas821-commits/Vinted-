import Foundation

enum TimeFormatting {
    /// `mm:ss` below an hour, `h:mm:ss` from an hour on.
    static func clock(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded(.down)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, seconds)
        }
        return String(format: "%02ld:%02ld", minutes, seconds)
    }
}

/// The transcribed text of one audio chunk.
struct TranscriptSegment: Equatable, Sendable {
    let index: Int
    let startTime: TimeInterval
    let text: String
}

enum TranscriptFormatter {
    /// Renders segments in recording order as timestamped paragraphs, e.g. `[01:30] ...`.
    /// The timestamps give the note generator a sense of the lecture's timeline.
    static func render(_ segments: [TranscriptSegment]) -> String {
        segments
            .sorted { $0.index < $1.index }
            .map { "[\(TimeFormatting.clock($0.startTime))] \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// The end of the preceding text, trimmed to whole words, for Whisper's `prompt`
    /// parameter. Whisper only reads the last ~224 tokens, so a few hundred characters
    /// are enough to carry spelling and terminology across chunk boundaries.
    static func promptContext(from previousText: String?, maxCharacters: Int = 600) -> String? {
        guard let previousText else { return nil }
        let trimmed = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCharacters else { return trimmed }

        let tail = trimmed.suffix(maxCharacters)
        if let firstSpace = tail.firstIndex(of: " ") {
            let wordAligned = tail[tail.index(after: firstSpace)...]
            if !wordAligned.isEmpty {
                return String(wordAligned)
            }
        }
        return String(tail)
    }
}

enum NotesFormatting {
    /// The text of the first `# ` heading, if any.
    static func title(from markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let title = trimmed.dropFirst(2)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return title.isEmpty ? nil : title
        }
        return nil
    }

    /// A filesystem-safe `.md` file name based on the notes' title, falling back to the date.
    static func suggestedFileName(for markdown: String, date: Date = Date()) -> String {
        let fallback = "Lecture Notes \(dayStamp(for: date))"
        let base = title(from: markdown).map(sanitizedFileName) ?? fallback
        return "\(base.isEmpty ? fallback : base).md"
    }

    /// `yyyy-MM-dd` in the user's time zone.
    static func dayStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let withoutLeadingDots = cleaned.drop { $0 == "." }
        return String(withoutLeadingDots.prefix(120)).trimmingCharacters(in: .whitespaces)
    }
}
