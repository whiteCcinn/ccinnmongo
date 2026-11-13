/// A parse failure with a precise, 1-based source position.
public struct SyntaxError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    /// UTF-16 offset of the offending character (or the end of input).
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(message: String, offset: Int, line: Int, column: Int) {
        self.message = message
        self.offset = offset
        self.line = line
        self.column = column
    }

    init(message: String, offset: Int, in units: [UInt16]) {
        var line = 1
        var column = 1
        let end = min(max(offset, 0), units.count)
        for index in 0..<end {
            if units[index] == Ascii.newline {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        self.init(message: message, offset: end, line: line, column: column)
    }

    public var description: String { "\(message) (line \(line), column \(column))" }
}
