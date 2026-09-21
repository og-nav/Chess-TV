// Where broadcast data comes from. Lichess in production; a directory of fixtures in the tests
// and in `--replay`.

import ChessCore
import Foundation

public enum BroadcastSourceError: Error, Sendable, Equatable {
    /// 429. The caller must back off for at least `ServerConfig.rateLimitBackoff` — Lichess asks
    /// for it and this server holds several long-lived connections from one IP.
    case rateLimited
    case http(Int)
    case malformed(String)
    case unavailable(String)
}

public protocol BroadcastSource: Sendable {
    /// `GET /api/broadcast/top` — the active and upcoming broadcasts.
    func top() async throws -> BroadcastTop
    /// `GET /api/broadcast/{tourId}` — the tour with its full round list.
    func tour(id: String) async throws -> BroadcastTourDetail
    /// `GET /api/broadcast/-/-/{roundId}` — the round with its boards, in board order.
    func round(id: String) async throws -> BroadcastRoundDetail
    /// `GET /api/stream/broadcast/round/{roundId}.pgn` — one element per re-sent game block, for
    /// as long as the round is live.
    func pgnStream(roundId: String) -> AsyncThrowingStream<String, any Error>
}

/// Splits a broadcast PGN stream into whole game blocks.
///
/// The stream re-sends a game's *entire* PGN every time it changes, so a block is self-contained
/// and the boundary is the only thing that has to be got right. Two things about that boundary
/// were wrong here and are the reason this is written in bytes and lines rather than in `String`
/// and `range(of:)`:
///
///   1. **A block must complete on its own.** Waiting for the next `"\n\n[Event"` means a game is
///      held back until some *other* game moves. On a one-board championship nothing is ever
///      emitted while the stream is open; on a multi-board round every alert lags a move and the
///      final result of the last game to finish never arrives at all. A block therefore also ends
///      at a **blank line after movetext that ends in a result token**, which is how the endpoint
///      actually closes a game it is about to re-send.
///   2. **A chunk boundary is not a character boundary.** `String(buffer:)` on a chunk that ends
///      halfway through a multi-byte sequence substitutes U+FFFD, so `Nepomniachtchi` or a
///      federation with an accent in it comes out corrupted — permanently, because the bytes are
///      gone by the time the next chunk arrives. Bytes are accumulated to a newline and only then
///      decoded.
///
/// This is the framing `BroadcastPGNStream` in LichessKit already uses on the app side; keeping
/// the two the same means a block the TV app can read is a block the server can read.
public struct PGNStreamSplitter: Sendable {

    private var lines = PGNLineDecoder()
    private var assembler = PGNBlockAssembler()

    public init() {}

    /// Feeds raw bytes from the stream and takes out whatever complete blocks they finished.
    public mutating func append(bytes: some Sequence<UInt8>) -> [String] {
        var blocks: [String] = []
        for line in lines.append(bytes) {
            if let block = assembler.append(line: line) { blocks.append(block) }
        }
        return blocks
    }

    /// The same, for a chunk that is already text — a fixture, or a test.
    public mutating func append(_ text: String) -> [String] {
        append(bytes: text.utf8)
    }

    /// Whatever is still being collected, once the stream has ended: a final game whose trailing
    /// blank line never arrived because the connection closed on the result.
    public mutating func flush() -> String? {
        if let tail = lines.flush() {
            if let block = assembler.append(line: tail) { return block }
        }
        return assembler.finish()
    }

    /// Splits a whole document at once — a recorded stream from `Fixtures/`.
    public static func blocks(in document: String) -> [String] {
        var splitter = PGNStreamSplitter()
        var blocks = splitter.append(document)
        if let last = splitter.flush() { blocks.append(last) }
        return blocks
    }
}

/// Turns the stream's bytes into lines, **keeping the blank ones**: in PGN a blank line is
/// structure, not filler.
struct PGNLineDecoder: Sendable {
    /// A PGN line longer than this is not something we can use. A hundred-move game's movetext
    /// with clock comments is on the order of ten kilobytes.
    static let maximumLineBytes = 1 << 20

    private var buffer: [UInt8] = []
    private var overflowing = false

    mutating func append(byte: UInt8) -> String? {
        guard byte != UInt8(ascii: "\n") else { return takeLine() }
        guard !overflowing else { return nil }
        buffer.append(byte)
        if buffer.count > Self.maximumLineBytes {
            buffer.removeAll(keepingCapacity: false)
            overflowing = true
        }
        return nil
    }

    mutating func append(_ chunk: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if let line = append(byte: byte) { lines.append(line) }
        }
        return lines
    }

    /// Whatever is left at end of body, if anything.
    mutating func flush() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String? {
        defer {
            buffer.removeAll(keepingCapacity: true)
            overflowing = false
        }
        guard !overflowing else { return nil }
        var bytes = buffer[...]
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
        // The whole line is here, so this decode cannot land inside a multi-byte sequence.
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Collects PGN lines until one game is complete.
///
/// A game ends at whichever comes first:
/// * a **tag line after movetext** — the next game's `[Event …]`; or
/// * a **blank line after movetext ending in a result token** (`*`, `1-0`, `0-1`, `1/2-1/2`).
///
/// The blank line between a game's own tags and its movetext never splits anything, because no
/// movetext has been seen at that point.
struct PGNBlockAssembler: Sendable {
    private var lines: [String] = []
    private var sawMovetext = false
    private var movetextEndsWithResult = false

    /// Feeds one line. Returns a complete game block when the line completed one.
    mutating func append(line raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)

        if line.isEmpty {
            guard sawMovetext, movetextEndsWithResult else { return nil }
            return take()
        }

        if Self.isTagLine(line) {
            guard sawMovetext else {
                lines.append(line)
                return nil
            }
            let block = take()
            lines.append(line)
            return block
        }

        sawMovetext = true
        lines.append(line)
        movetextEndsWithResult = Self.endsWithResult(line)
        return nil
    }

    /// The block still being collected, at end of body.
    mutating func finish() -> String? {
        guard sawMovetext else { return nil }
        return take()
    }

    private mutating func take() -> String? {
        defer {
            lines.removeAll(keepingCapacity: true)
            sawMovetext = false
            movetextEndsWithResult = false
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isTagLine(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]") && line.contains("\"")
    }

    private static func endsWithResult(_ line: String) -> Bool {
        guard let last = line.split(separator: " ").last else { return false }
        return PGN.isResultToken(String(last))
    }
}
