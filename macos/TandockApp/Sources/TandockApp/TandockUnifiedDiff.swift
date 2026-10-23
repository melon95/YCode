import SwiftUI

struct TandockUnifiedDiff {
    struct Line: Identifiable {
        enum Kind {
            case context, addition, deletion, meta

            var color: Color {
                switch self {
                case .addition: .tandockOK
                case .deletion: .tandockErr
                case .meta: .secondary
                case .context: .primary
                }
            }

            var background: Color {
                switch self {
                case .addition: Color.tandockOK.opacity(0.10)
                case .deletion: Color.tandockErr.opacity(0.09)
                default: .clear
                }
            }
        }

        let id: Int
        let text: String
        let kind: Kind
        let number: Int?
    }

    struct Hunk: Identifiable {
        let id: Int
        let header: String
        let lines: [Line]

        var patchBody: String {
            ([header] + lines.map(\.text)).joined(separator: "\n") + "\n"
        }
    }

    private static func startLines(of header: String) -> (Int, Int) {
        let numbers = header
            .split(separator: "@")
            .first { $0.contains("-") || $0.contains("+") }?
            .split(separator: " ")
            .compactMap { piece -> Int? in
                let digits = piece.dropFirst().split(separator: ",").first ?? ""
                return Int(digits)
            } ?? []
        return (numbers.first ?? 1, numbers.count > 1 ? numbers[1] : numbers.first ?? 1)
    }

    let fileHeader: String
    let hunks: [Hunk]

    init(text: String) {
        var headerLines: [String] = []
        var hunks: [Hunk] = []
        var currentHeader: String?
        var currentLines: [Line] = []
        var lineID = 0
        var oldLine = 0
        var newLine = 0

        func flush() {
            guard let header = currentHeader else { return }
            hunks.append(Hunk(id: hunks.count, header: header, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("@@") {
                flush()
                currentHeader = raw
                (oldLine, newLine) = Self.startLines(of: raw)
                continue
            }
            guard currentHeader != nil else {
                if !raw.isEmpty { headerLines.append(raw) }
                continue
            }
            lineID += 1
            let kind: Line.Kind
            var number: Int?
            if raw.hasPrefix("+") {
                kind = .addition
                number = newLine
                newLine += 1
            } else if raw.hasPrefix("-") {
                kind = .deletion
                number = oldLine
                oldLine += 1
            } else if raw.hasPrefix("\\") {
                kind = .meta
            } else {
                kind = .context
                number = newLine
                oldLine += 1
                newLine += 1
            }
            currentLines.append(Line(id: lineID, text: raw, kind: kind, number: number))
        }
        flush()

        fileHeader = headerLines.isEmpty ? "" : headerLines.joined(separator: "\n") + "\n"
        self.hunks = hunks
    }
}
