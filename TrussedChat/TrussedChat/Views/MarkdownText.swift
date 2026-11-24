import SwiftUI

/// Lightweight Markdown renderer for chat bubbles.
/// Block-level: headings, bullet / numbered lists, block quotes, code fences, rules, paragraphs.
/// Inline (via AttributedString): **bold**, *italic*, `code`, ~~strike~~, [links](url).
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, marker: String, text: String)
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                Self.inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                Self.inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Self.inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider().padding(.vertical, 2)
        case .paragraph(let text):
            Self.inline(text)
        }
    }

    /// Renders inline Markdown, preserving line breaks. Falls back to plain text if parsing fails.
    static func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(source)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for rawLine in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Code fences
            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            let leading = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            let indent = min(leading / 2, 3)

            if let heading = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.0, text: heading.1))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
            } else if let bullet = bulletMatch(trimmed) {
                flushParagraph()
                blocks.append(.bullet(indent: indent, text: bullet))
            } else if let numbered = numberedMatch(trimmed) {
                flushParagraph()
                blocks.append(.numbered(indent: indent, marker: numbered.0, text: numbered.1))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = codeLines { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func headingMatch(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletMatch(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedMatch(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let sep = rest.first, sep == "." || sep == ")", rest.dropFirst().first == " " else { return nil }
        return ("\(digits).", String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
}

#Preview {
    MarkdownText(text: """
    ## Weather in Durham, NC
    It's **60°F** and *overcast* right now. See [Open-Meteo](https://open-meteo.com).

    - Feels like `58°F`
    - Wind 8.5 mph from the NNW
    1. Tue: Moderate drizzle
    2. Wed: Moderate rain
    """)
    .padding()
}
