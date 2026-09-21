import Foundation

/// Turns an arbitrary sequence of byte chunks into complete NDJSON lines.
///
/// The network hands us bytes with no respect for line or character boundaries, so this
/// buffers until it sees a `\n`:
/// * a JSON object split across two chunks is reassembled;
/// * several objects in one chunk come back as several lines;
/// * a multi-byte UTF-8 sequence straddling a chunk boundary is decoded correctly,
///   because decoding happens on the whole line, never on a chunk;
/// * blank keep-alive lines are swallowed;
/// * a line longer than `maxLineBytes` is dropped rather than growing without bound.
///
/// It is a value type with no I/O, so it is trivially testable and `Sendable`.
public struct NDJSONLineDecoder: Sendable {
    /// Anything longer than this is not a Lichess TV event; drop it instead of buffering forever.
    public static let maxLineBytes = 1 << 20   // 1 MiB

    private var buffer: [UInt8] = []
    private var overflowing = false

    /// Number of lines dropped because they exceeded `maxLineBytes`.
    public private(set) var droppedLineCount = 0

    public init() {}

    /// Feeds one byte. Returns a complete line when the byte terminated one.
    public mutating func append(byte: UInt8) -> String? {
        guard byte != UInt8(ascii: "\n") else { return takeLine() }
        guard !overflowing else { return nil }
        buffer.append(byte)
        if buffer.count > Self.maxLineBytes {
            log.error("NDJSON line exceeded \(Self.maxLineBytes) bytes; dropping until the next newline")
            buffer.removeAll(keepingCapacity: false)
            overflowing = true
            droppedLineCount += 1
        }
        return nil
    }

    /// Feeds a chunk of bytes. Returns every complete line the chunk finished.
    public mutating func append(_ chunk: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if let line = append(byte: byte) { lines.append(line) }
        }
        return lines
    }

    /// Returns whatever is left in the buffer at end of stream, if it is not blank.
    /// Lichess terminates every event with a newline, so a non-nil result means a truncated line.
    public mutating func flush() -> String? {
        takeLine()
    }

    /// `true` when no partial line is buffered.
    public var isEmpty: Bool { buffer.isEmpty }

    private mutating func takeLine() -> String? {
        defer {
            buffer.removeAll(keepingCapacity: true)
            overflowing = false
        }
        guard !overflowing, !buffer.isEmpty else { return nil }
        // Decoding the complete line is what makes split multi-byte scalars safe.
        var bytes = buffer[...]
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }       // tolerate CRLF
        let line = String(decoding: bytes, as: UTF8.self)
        // Keep-alive newlines and whitespace-only lines carry no event.
        return line.allSatisfy(\.isWhitespace) ? nil : line
    }
}
