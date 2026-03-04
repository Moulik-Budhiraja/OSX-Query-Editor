import AppKit

enum OXAColorTheme {
    static let baseText = NSColor.labelColor
    static let keywordToken = NSColor(srgbRed: 0.40, green: 0.68, blue: 1.00, alpha: 1)
    static let stringToken = NSColor(srgbRed: 0.42, green: 0.89, blue: 0.50, alpha: 1)
    static let referenceToken = NSColor(srgbRed: 0.97, green: 0.84, blue: 0.22, alpha: 1)
    static let attributeToken = NSColor(srgbRed: 0.98, green: 0.56, blue: 0.14, alpha: 1)
    static let numberToken = NSColor(srgbRed: 0.86, green: 0.35, blue: 0.78, alpha: 1)

    private static let keywords: Set<String> = [
        "send",
        "text",
        "as",
        "keys",
        "to",
        "click",
        "right",
        "drag",
        "hotkey",
        "scroll",
        "read",
        "from",
        "sleep",
        "open",
        "close",
        "up",
        "down",
        "left",
        "right",
    ]

    static func highlightedProgram(_ source: String, font: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: self.baseText,
            ])

        guard !source.isEmpty else {
            return output
        }

        var index = source.startIndex
        var expectAttributeName = false

        while index < source.endIndex {
            let character = source[index]

            if character == "\"" {
                let literalRange = self.consumeStringLiteral(in: source, from: index)
                self.paint(range: literalRange, in: source, output: output, color: self.stringToken)
                index = literalRange.upperBound
                continue
            }

            if self.isIdentifierCharacter(character) {
                let start = index
                index = self.consumeIdentifier(in: source, from: start)
                let token = String(source[start..<index])
                let lower = token.lowercased()

                if expectAttributeName {
                    self.paint(range: start..<index, in: source, output: output, color: self.attributeToken)
                    expectAttributeName = false
                    continue
                }

                if lower == "read" {
                    self.paint(range: start..<index, in: source, output: output, color: self.keywordToken)
                    expectAttributeName = true
                    continue
                }

                if self.keywords.contains(lower) {
                    self.paint(range: start..<index, in: source, output: output, color: self.keywordToken)
                    continue
                }

                if self.isReferenceToken(lower) {
                    self.paint(range: start..<index, in: source, output: output, color: self.referenceToken)
                    continue
                }

                if token.allSatisfy(\.isNumber) {
                    self.paint(range: start..<index, in: source, output: output, color: self.numberToken)
                }

                continue
            }

            if !character.isWhitespace {
                expectAttributeName = false
            }
            index = source.index(after: index)
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

    private static func consumeStringLiteral(in source: String, from startIndex: String.Index) -> Range<String.Index> {
        var index = source.index(after: startIndex)
        var escaped = false

        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
                index = source.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = source.index(after: index)
                continue
            }
            if character == "\"" {
                index = source.index(after: index)
                break
            }
            index = source.index(after: index)
        }

        return startIndex..<index
    }

    private static func consumeIdentifier(in source: String, from start: String.Index) -> String.Index {
        var index = start
        while index < source.endIndex, self.isIdentifierCharacter(source[index]) {
            index = source.index(after: index)
        }
        return index
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
    }

    private static func isReferenceToken(_ token: String) -> Bool {
        guard token.count == 9 else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdef").contains(scalar)
        }
    }
}
