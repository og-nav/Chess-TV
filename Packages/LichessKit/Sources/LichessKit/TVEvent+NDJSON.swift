import Foundation

extension TVEvent {
    /// Decodes one NDJSON line of `/api/tv/{channel}/feed`.
    ///
    /// Exposed so consumers (and their tests) can decode a recorded feed without
    /// reimplementing the wire format. Returns `nil` for a blank line, a line whose `t` this
    /// version does not model, and a line that is not the JSON we expect — the same
    /// "log and skip" policy `TVFeedStream` applies mid-stream.
    public init?(ndjsonLine line: String) {
        guard let event = try? TVEventDecoder().decode(line: line) else { return nil }
        self = event
    }
}

/// Public wrapper around the package's NDJSON event decoding.
///
/// Prefer ``TVEvent/init(ndjsonLine:)``; this exists for callers that want to decode a whole
/// recording, or to distinguish "unknown event" from "malformed line".
public struct LichessTVEventDecoder: Sendable {
    private let decoder = TVEventDecoder()

    public init() {}

    /// - Returns: the event, or `nil` for a well-formed line with an event type we do not model.
    /// - Throws: `LichessError.malformedBody` (or a `DecodingError`) for a line that is not
    ///   the JSON we expect.
    public func decode(line: String) throws -> TVEvent? {
        try decoder.decode(line: line)
    }

    /// Decodes a whole NDJSON recording, skipping blank, unknown and malformed lines.
    public func decodeAll(_ data: Data) -> [TVEvent] {
        var lineDecoder = NDJSONLineDecoder()
        var lines = lineDecoder.append(data)
        if let tail = lineDecoder.flush() { lines.append(tail) }
        return lines.compactMap { try? decoder.decode(line: $0) }
    }
}
