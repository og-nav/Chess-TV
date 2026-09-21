// PGN: the format every broadcast round publishes.
//
// `GET /api/broadcast/round/{roundId}.pgn` (and its streaming twin) returns every game of a round
// as PGN, separated by blank lines. That is the only endpoint that carries a game's *history* —
// the board API gives the current FEN and nothing else — so a viewer who joins a broadcast
// halfway through gets the moves that were already played from here.
//
// The parser is deliberately forgiving, because real broadcast PGN contains everything the
// standard allows and then some: several `{ comments }` after one move, `(variations)` nested
// inside each other, NAGs both as glyphs (`?!`) and as numbers (`$1`), `12...` continuations
// after a comment, CRLF line endings, and a result token at the end. Anything it does not
// understand it skips; the one thing it will not do is silently mis-read a move.

// MARK: - Model

/// One ply of a PGN game: the move as written, plus whatever the comment after it carried.
public struct PGNMove: Sendable, Equatable {
    /// The move token exactly as the PGN spelled it, decoration included (`Rb7?!`, `d8=Q+`).
    public let san: String
    /// The move number the token was written under, when the PGN stated one.
    public let moveNumber: Int?
    /// The comment text with the `[%…]` commands removed, or nil when nothing else was there.
    public let comment: String?
    /// The mover's remaining time, from `[%clk h:mm:ss]`.
    public let clock: Duration?
    /// The evaluation as written, from `[%eval …]`: `"0.1"`, `"-1.25"`, `"#17"`.
    public let eval: String?

    public init(san: String, moveNumber: Int? = nil, comment: String? = nil, clock: Duration? = nil, eval: String? = nil) {
        self.san = san
        self.moveNumber = moveNumber
        self.comment = comment
        self.clock = clock
        self.eval = eval
    }

    /// The clock rounded down to whole seconds, which is how `TVEvent` carries it.
    public var clockSeconds: Int? {
        clock.map { Int($0.components.seconds) }
    }
}

/// One game: its tag pairs, its moves, and its result token.
public struct PGNGame: Sendable, Equatable {
    /// The tag pairs, by name: `Event`, `White`, `BlackElo`, `GameURL`, …
    public let tags: [String: String]
    public let moves: [PGNMove]
    /// The result token that closed the movetext (`"1-0"`, `"0-1"`, `"1/2-1/2"`, `"*"`), or the
    /// `Result` tag when the movetext had none.
    public let result: String?

    public init(tags: [String: String], moves: [PGNMove], result: String?) {
        self.tags = tags
        self.moves = moves
        self.result = result
    }

    public subscript(tag: String) -> String? { tags[tag] }

    public var white: String? { tags["White"] }
    public var black: String? { tags["Black"] }
    public var whiteTitle: String? { tags["WhiteTitle"] }
    public var blackTitle: String? { tags["BlackTitle"] }
    public var whiteElo: Int? { tags["WhiteElo"].flatMap(Int.init) }
    public var blackElo: Int? { tags["BlackElo"].flatMap(Int.init) }

    /// `[GameURL "https://lichess.org/broadcast/<slug>/round-N/<roundId>/<gameId>"]`.
    public var gameURL: String? { tags["GameURL"] }

    /// The game id a broadcast `GameURL` ends with, or the `Site` URL's last component.
    public var gameId: String? {
        let url = gameURL ?? tags["Site"]
        guard let url else { return nil }
        let components = url.split(separator: "/").filter { !$0.isEmpty }
        guard let last = components.last, !last.contains(".") else { return nil }
        return String(last)
    }

    /// `true` once the game has a result — anything but `*`.
    public var isFinished: Bool {
        guard let outcome, !outcome.isEmpty else { return false }
        return outcome != "*"
    }

    /// The result token if there is one, otherwise the `Result` tag.
    public var outcome: String? { result ?? tags["Result"] }

    /// Where the movetext starts: the `FEN` tag when the game sets one up, else the standard
    /// starting position.
    public var initialPosition: Position {
        guard let fen = tags["FEN"], let position = try? Position(fen: fen) else { return .standard }
        return position
    }
}

/// A move in the movetext that is not legal in the position it was written for.
///
/// Carries the prefix that *did* replay, so a caller can show the moves up to the problem
/// rather than throwing the whole game away.
public struct PGNReplayError: Error, CustomStringConvertible, Sendable {
    /// 1-based ply index of the move that could not be played.
    public let ply: Int
    /// The move token as the PGN spelled it.
    public let san: String
    /// The FEN of the position the move was to be played in.
    public let fen: String
    /// Everything before `ply`, already replayed.
    public let replayed: [(san: String, uci: String, fen: String)]

    public init(ply: Int, san: String, fen: String, replayed: [(san: String, uci: String, fen: String)]) {
        self.ply = ply
        self.san = san
        self.fen = fen
        self.replayed = replayed
    }

    public var description: String {
        let moveNumber = (ply + 1) / 2
        let side = ply % 2 == 1 ? "white" : "black"
        return "PGN ply \(ply) (move \(moveNumber), \(side)): '\(san)' is not legal in \(fen)"
    }
}

extension PGNGame {

    /// Replays the movetext, returning one entry per ply: the move as written, its UCI, and the
    /// FEN *after* it.
    ///
    /// - Throws: `PGNReplayError` naming the first ply that is not a legal move, with the prefix
    ///   that replayed cleanly attached.
    public func replay(from start: Position = .standard) throws -> [(san: String, uci: String, fen: String)] {
        var position = start
        var steps: [(san: String, uci: String, fen: String)] = []
        steps.reserveCapacity(moves.count)
        for (index, move) in moves.enumerated() {
            guard let played = SAN.move(forSAN: move.san, in: position) else {
                throw PGNReplayError(ply: index + 1, san: move.san, fen: position.fen, replayed: steps)
            }
            position = position.making(played)
            steps.append((san: move.san, uci: played.uci, fen: position.fen))
        }
        return steps
    }
}

// MARK: - Parsing

public enum PGN {

    /// Every game in a PGN document.
    ///
    /// Games are split where a tag section starts after movetext — the "blank line then `[`"
    /// boundary — so a game's own `[Event …]` block, which is *followed* by a blank line and then
    /// its moves, never splits it in two. Blank lines, `%` escape lines, CRLF endings and leading
    /// junk are all tolerated.
    public static func parseGames(_ text: String) -> [PGNGame] {
        var games: [PGNGame] = []
        var tags: [String: String] = [:]
        var movetext = ""
        var sawMovetext = false

        func flush() {
            defer {
                tags = [:]
                movetext = ""
                sawMovetext = false
            }
            guard !tags.isEmpty || sawMovetext else { return }
            let parsed = parseMovetext(movetext)
            games.append(PGNGame(tags: tags, moves: parsed.moves, result: parsed.result ?? tags["Result"]))
        }

        // A CRLF is a *single* Character in Swift, so the separator has to name all three
        // spellings; splitting on "\n" alone would not break a CRLF document into lines at all.
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        for line in lines {
            let trimmed = line.sanTrimmedSlice()
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("%") { continue }              // the PGN escape mechanism
            if isTagLine(trimmed) {
                if sawMovetext { flush() }
                if let pair = parseTag(trimmed) { tags[pair.name] = pair.value }
            } else {
                sawMovetext = true
                movetext += trimmed
                movetext += "\n"
            }
        }
        flush()
        return games
    }

    /// The first game of a PGN document — a single broadcast game block, typically.
    public static func parseGame(_ text: String) -> PGNGame? { parseGames(text).first }

    // MARK: Tags

    private static func isTagLine(_ line: Substring) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.contains("\"") else { return false }
        // `[Event "…"]`: a name, whitespace, then a quoted value.
        let body = line.dropFirst()
        guard let first = body.first, first.isLetter else { return false }
        return body.contains(" ")
    }

    private static func parseTag(_ line: Substring) -> (name: String, value: String)? {
        let body = line.dropFirst().dropLast()
        guard let space = body.firstIndex(of: " ") else { return nil }
        let name = String(body[body.startIndex..<space]).sanTrimmed()
        let rest = body[body.index(after: space)...].sanTrimmedSlice()
        guard rest.hasPrefix("\""), rest.count >= 2, rest.hasSuffix("\"") else { return nil }
        let quoted = rest.dropFirst().dropLast()

        var value = ""
        var escaped = false
        for character in quoted {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                value.append(character)
            }
        }
        return name.isEmpty ? nil : (name, value)
    }

    // MARK: Movetext

    private static let resultTokens: Set<String> = ["1-0", "0-1", "1/2-1/2", "½-½", "0.5-0.5", "*"]

    /// `true` when the token closes a game.
    public static func isResultToken(_ token: String) -> Bool { resultTokens.contains(token) }

    static func parseMovetext(_ text: String) -> (moves: [PGNMove], result: String?) {
        var moves: [PGNMove] = []
        var result: String?
        var pendingNumber: Int?

        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }

            switch character {
            case "{":
                let comment = readComment(characters, from: &index)
                attach(comment: comment, to: &moves)
            case "(":
                skipVariation(characters, from: &index)
            case ";":
                while index < characters.count, characters[index] != "\n" { index += 1 }
            case "$":
                index += 1
                while index < characters.count, characters[index].isNumber { index += 1 }
            case ")", "}":
                index += 1                                     // stray closer: ignore it
            default:
                var token = ""
                while index < characters.count,
                      !characters[index].isWhitespace,
                      !"{()};".contains(characters[index]) {
                    token.append(characters[index])
                    index += 1
                }
                if token.isEmpty { index += 1; continue }
                if resultTokens.contains(token) {
                    result = token
                    continue
                }
                // `12.`, `12...`, and the glued forms `12.Nf3` / `12...Nf6`.
                var rest = Substring(token)
                if let first = rest.first, first.isNumber {
                    var digits = ""
                    while let next = rest.first, next.isNumber { digits.append(next); rest.removeFirst() }
                    if rest.first == "." {
                        while rest.first == "." { rest.removeFirst() }
                        pendingNumber = Int(digits)
                    } else {
                        rest = Substring(token)                 // not a move number after all
                    }
                }
                let san = String(rest)
                guard !san.isEmpty else { continue }
                moves.append(PGNMove(san: san, moveNumber: pendingNumber))
                // Only the first move after a number carries it; Black's is stated separately.
                pendingNumber = nil
            }
        }
        return (moves, result)
    }

    /// Reads `{ … }` from `index`, which must point at the opening brace. PGN comments do not nest.
    private static func readComment(_ characters: [Character], from index: inout Int) -> String {
        index += 1
        var text = ""
        while index < characters.count, characters[index] != "}" {
            text.append(characters[index])
            index += 1
        }
        if index < characters.count { index += 1 }             // the closing brace
        return text
    }

    /// Skips `( … )` from `index`, counting nesting and stepping over comments inside, so that a
    /// `)` written in a comment does not end the variation early.
    private static func skipVariation(_ characters: [Character], from index: inout Int) {
        var depth = 0
        while index < characters.count {
            switch characters[index] {
            case "(":
                depth += 1
                index += 1
            case ")":
                depth -= 1
                index += 1
                if depth <= 0 { return }
            case "{":
                _ = readComment(characters, from: &index)
            default:
                index += 1
            }
        }
    }

    /// Merges a comment into the move it follows, pulling `[%clk]` and `[%eval]` out of it.
    /// A comment before the first move belongs to the game, not to a ply, and is dropped.
    private static func attach(comment: String, to moves: inout [PGNMove]) {
        guard let last = moves.popLast() else { return }
        let parsed = parseComment(comment)
        let text = [last.comment, parsed.text].compactMap { $0 }.joined(separator: " ").sanTrimmed()
        moves.append(PGNMove(
            san: last.san,
            moveNumber: last.moveNumber,
            comment: text.isEmpty ? nil : text,
            clock: parsed.clock ?? last.clock,
            eval: parsed.eval ?? last.eval
        ))
    }

    /// Splits a comment into its `[%command value]` annotations and the prose that is left.
    static func parseComment(_ comment: String) -> (text: String?, clock: Duration?, eval: String?) {
        var prose = ""
        var clock: Duration?
        var eval: String?

        let characters = Array(comment)
        var index = 0
        while index < characters.count {
            if characters[index] == "[", index + 1 < characters.count, characters[index + 1] == "%" {
                var body = ""
                index += 2
                while index < characters.count, characters[index] != "]" {
                    body.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
                let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let name = parts.first else { continue }
                let value = parts.count > 1 ? String(parts[1]).sanTrimmed() : ""
                switch name {
                case "clk": clock = duration(fromClock: value)
                case "eval": eval = value.isEmpty ? nil : value
                default: break                                 // %emt, %csl, %cal, … are not ours
                }
            } else {
                prose.append(characters[index])
                index += 1
            }
        }

        let text = prose.sanTrimmed()
        return (text.isEmpty ? nil : text, clock, eval)
    }

    /// `"0:30:00"`, `"12:04"`, `"0:00:09.7"` → a `Duration`. Nil when it is not a clock at all.
    public static func duration(fromClock text: String) -> Duration? {
        let parts = text.sanTrimmed().split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return .seconds(total)
    }
}

extension StringProtocol {
    /// Whitespace-trimmed, as a slice, without pulling in Foundation.
    func sanTrimmedSlice() -> SubSequence {
        var slice = self[startIndex..<endIndex]
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }
}
