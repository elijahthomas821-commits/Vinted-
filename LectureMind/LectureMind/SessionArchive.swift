import Foundation

/// Keeps a copy of each session's transcript and notes on disk, so a crash, a failed note
/// generation, or starting the next recording never loses a lecture.
struct SessionArchive: Sendable {
    let rootDirectory: URL

    /// `~/Library/Application Support/LectureMind/Sessions`
    static var defaultRootDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport.appendingPathComponent("LectureMind/Sessions", isDirectory: true)
    }

    func directory(forSessionStartedAt startDate: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return rootDirectory.appendingPathComponent(formatter.string(from: startDate), isDirectory: true)
    }

    @discardableResult
    func saveTranscript(_ transcript: String, sessionStartedAt startDate: Date) throws -> URL {
        try write(transcript, fileName: "transcript.md", sessionStartedAt: startDate)
    }

    @discardableResult
    func saveNotes(_ notes: String, sessionStartedAt startDate: Date) throws -> URL {
        try write(notes, fileName: "notes.md", sessionStartedAt: startDate)
    }

    private func write(_ text: String, fileName: String, sessionStartedAt startDate: Date) throws -> URL {
        let directory = directory(forSessionStartedAt: startDate)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}
