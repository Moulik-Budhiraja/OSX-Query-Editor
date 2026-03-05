import AppKit
import SwiftUI

enum OXQColorTheme {
    static let roleToken = NSColor(srgbRed: 0.97, green: 0.84, blue: 0.22, alpha: 1)
    static let attributeToken = NSColor(srgbRed: 0.98, green: 0.56, blue: 0.14, alpha: 1)
    static let stringToken = NSColor(srgbRed: 0.42, green: 0.89, blue: 0.50, alpha: 1)
    static let functionToken = NSColor(srgbRed: 0.40, green: 0.68, blue: 1.00, alpha: 1)
    static let baseText = NSColor.labelColor

    static let rolePalette: [NSColor] = [
        NSColor(srgbRed: 0.86, green: 0.25, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.26, green: 0.78, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.74, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.57, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.86, green: 0.35, blue: 0.78, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.79, blue: 0.83, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.45, blue: 0.37, alpha: 1),
        NSColor(srgbRed: 0.49, green: 0.88, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.99, green: 0.86, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.49, green: 0.71, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.52, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.89, blue: 0.90, alpha: 1),
    ]

    static func swiftUIColor(forRole role: String) -> Color {
        Color(nsColor: self.nsColor(forRole: role))
    }

    static func nsColor(forRole role: String) -> NSColor {
        let stableHash = role.utf8.reduce(UInt64(5381)) { partial, byte in
            ((partial << 5) &+ partial) &+ UInt64(byte)
        }
        let index = Int(stableHash % UInt64(self.rolePalette.count))
        return self.rolePalette[index]
    }

    static func highlightedQuery(_ query: String, font: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: query,
            attributes: [
                .font: font,
                .foregroundColor: self.baseText,
            ])

        guard !query.isEmpty else {
            return output
        }

        var index = query.startIndex
        var attributeBracketDepth = 0
        var expectingAttributeName = false

        while index < query.endIndex {
            let character = query[index]

            if character == "[" {
                attributeBracketDepth += 1
                expectingAttributeName = true
                index = query.index(after: index)
                continue
            }

            if character == "]" {
                if attributeBracketDepth > 0 {
                    attributeBracketDepth -= 1
                }
                expectingAttributeName = false
                index = query.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                let literalRange = self.consumeStringLiteral(in: query, from: index)
                self.paint(range: literalRange, in: query, output: output, color: self.stringToken)
                index = literalRange.upperBound
                continue
            }

            if character == ":" {
                index = query.index(after: index)

                while index < query.endIndex, query[index].isWhitespaceLike {
                    index = query.index(after: index)
                }

                if index < query.endIndex, self.isIdentifierStart(query[index]) {
                    let start = index
                    index = self.consumeIdentifier(in: query, from: start)
                    self.paint(range: start..<index, in: query, output: output, color: self.functionToken)
                }
                continue
            }

            if attributeBracketDepth > 0 {
                if expectingAttributeName {
                    if character.isWhitespaceLike {
                        index = query.index(after: index)
                        continue
                    }

                    if character == "," {
                        index = query.index(after: index)
                        expectingAttributeName = true
                        continue
                    }

                    if self.isIdentifierStart(character) {
                        let start = index
                        index = self.consumeIdentifier(in: query, from: start)
                        self.paint(range: start..<index, in: query, output: output, color: self.attributeToken)
                        expectingAttributeName = false
                        continue
                    }

                    index = query.index(after: index)
                    continue
                }

                if character == "," {
                    expectingAttributeName = true
                }
                index = query.index(after: index)
                continue
            }

            if self.isIdentifierStart(character) {
                let start = index
                index = self.consumeIdentifier(in: query, from: start)
                self.paint(range: start..<index, in: query, output: output, color: self.roleToken)
                continue
            }

            index = query.index(after: index)
        }

        return output
    }

    private static func paint(
        range: Range<String.Index>,
        in text: String,
        output: NSMutableAttributedString,
        color: NSColor)
    {
        let nsRange = NSRange(range, in: text)
        output.addAttribute(.foregroundColor, value: color, range: nsRange)
    }

    private static func consumeStringLiteral(in query: String, from startIndex: String.Index) -> Range<String.Index> {
        let quote = query[startIndex]
        var index = query.index(after: startIndex)
        var escaped = false

        while index < query.endIndex {
            let character = query[index]
            if escaped {
                escaped = false
                index = query.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = query.index(after: index)
                continue
            }
            if character == quote {
                index = query.index(after: index)
                break
            }
            index = query.index(after: index)
        }

        return startIndex..<index
    }

    private static func consumeIdentifier(in query: String, from start: String.Index) -> String.Index {
        var index = start
        while index < query.endIndex, self.isIdentifierContinue(query[index]) {
            index = query.index(after: index)
        }
        return index
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar) || scalar == "_"
        }
    }

    private static func isIdentifierContinue(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }
}

private extension Character {
    var isWhitespaceLike: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
