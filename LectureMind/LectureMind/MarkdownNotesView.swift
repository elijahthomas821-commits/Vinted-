import SwiftUI

/// The block-level Markdown the note prompt produces: headings, nested bullets, task items,
/// numbered lists, quotes, rules, code, and paragraphs. Inline styling (bold, italics, code,
/// links) is left to `AttributedString(markdown:)`, which only handles inline syntax.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(depth: Int, text: String)
    case task(depth: Int, text: String, isDone: Bool)
    case numbered(depth: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case rule
    case paragraph(String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var codeLines: [String]?

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }
            guard !trimmed.isEmpty else { continue }

            if let heading = heading(from: trimmed) {
                blocks.append(heading)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if let item = listItem(from: trimmed, depth: indentDepth(of: line)) {
                blocks.append(item)
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if let lines = codeLines, !lines.isEmpty {
            blocks.append(.code(lines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func indentDepth(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
        }
        return min(columns / 2, 6)
    }

    private static func heading(from line: String) -> MarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(from line: String, depth: Int) -> MarkdownBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let body = line.dropFirst(marker.count)
            let checkbox = body.prefix(3).lowercased()
            if checkbox == "[ ]" || checkbox == "[x]" {
                let text = body.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return .task(depth: depth, text: text, isDone: checkbox == "[x]")
            }
            return .bullet(depth: depth, text: body.trimmingCharacters(in: .whitespaces))
        }

        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .numbered(depth: depth, marker: "\(digits).", text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}

/// Renders generated notes as formatted, selectable text.
struct MarkdownNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 0 : 8)
        case .bullet(let depth, let text):
            listRow(depth: depth, marker: Text(depth == 0 ? "•" : "◦"), text: text)
        case .task(let depth, let text, let isDone):
            listRow(depth: depth, marker: Text(Image(systemName: isDone ? "checkmark.square" : "square")), text: text)
        case .numbered(let depth, let marker, let text):
            listRow(depth: depth, marker: Text(marker).monospacedDigit(), text: text)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(inline(text))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case .paragraph(let text):
            Text(inline(text))
        }
    }

    private func listRow(depth: Int, marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .foregroundStyle(.secondary)
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
