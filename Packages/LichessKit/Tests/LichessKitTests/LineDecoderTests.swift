import Foundation
import Testing
@testable import LichessKit

@Suite("NDJSON line decoder")
struct LineDecoderTests {

    /// Feeds `data` through the decoder in fixed-size chunks.
    private func lines(of data: Data, chunkSize: Int) -> [String] {
        var decoder = NDJSONLineDecoder()
        var lines: [String] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            lines += decoder.append(data[index..<end])
            index = end
        }
        if let tail = decoder.flush() { lines.append(tail) }
        return lines
    }

    @Test("Chunk size does not change the events", arguments: [1, 7, 1000])
    func chunkSizeIsIrrelevant(chunkSize: Int) throws {
        let data = try Fixture.castling.data
        let expected = try Fixture.castling.lines
        #expect(lines(of: data, chunkSize: chunkSize) == expected)

        let decoder = TVEventDecoder()
        let events = try lines(of: data, chunkSize: chunkSize).compactMap { try decoder.decode(line: $0) }
        #expect(events == (try Fixture.castling.events))
        #expect(events.count == 5)
    }

    @Test("All three fixtures survive 1-byte and 7-byte chunking", arguments: Fixture.allCases)
    func allFixturesSurviveChunking(fixture: Fixture) throws {
        let data = try fixture.data
        let expected = try fixture.lines
        #expect(lines(of: data, chunkSize: 1) == expected)
        #expect(lines(of: data, chunkSize: 7) == expected)
        #expect(lines(of: data, chunkSize: 1_000_000) == expected)
    }

    @Test("A multi-byte character split across a chunk boundary decodes correctly")
    func multibyteAcrossChunkBoundary() throws {
        // "é" is 0xC3 0xA9; the name also carries a 4-byte emoji to be thorough.
        let line = #"{"t":"featured","d":{"id":"acc00001","orientation":"white","players":[{"color":"white","user":{"name":"Renée♟️","id":"renee"},"rating":2400,"seconds":90},{"color":"black","user":{"name":"Björn","title":"GM","id":"bjorn"},"rating":2410,"seconds":90}],"fen":"8/8/8/8/8/8/8/8 w - - 0 1"}}"#
        let data = Data((line + "\n").utf8)
        let eIndex = try #require(data.firstIndex(of: 0xC3))   // lead byte of "é"

        // Split exactly between the lead byte and the continuation byte.
        var decoder = NDJSONLineDecoder()
        var produced = decoder.append(data[data.startIndex...eIndex])
        #expect(produced.isEmpty)
        produced += decoder.append(data[data.index(after: eIndex)...])
        #expect(produced == [line])

        let event = try #require(try TVEventDecoder().decode(line: produced[0]))
        guard case .featured(_, _, let players, _) = event else {
            Issue.record("expected a featured event"); return
        }
        #expect(players[0].name == "Renée♟️")
        #expect(players[1].name == "Björn")

        // And every possible split point of the same line yields the same one line.
        for split in 1..<data.count {
            var decoder = NDJSONLineDecoder()
            var lines = decoder.append(data[data.startIndex..<data.startIndex.advanced(by: split)])
            lines += decoder.append(data[data.startIndex.advanced(by: split)...])
            #expect(lines == [line], "split at \(split) produced \(lines)")
        }
    }

    @Test("Several complete lines in one chunk all come back")
    func multipleLinesInOneChunk() {
        var decoder = NDJSONLineDecoder()
        #expect(decoder.append(Data("a\nb\nc\n".utf8)) == ["a", "b", "c"])
        #expect(decoder.isEmpty)
    }

    @Test("Blank keep-alive lines are swallowed")
    func blankLines() {
        var decoder = NDJSONLineDecoder()
        #expect(decoder.append(Data("\n\n \n\r\n".utf8)).isEmpty)
        #expect(decoder.append(Data("{}\n".utf8)) == ["{}"])
        #expect(decoder.flush() == nil)
    }

    @Test("CRLF terminators are tolerated")
    func crlf() {
        var decoder = NDJSONLineDecoder()
        #expect(decoder.append(Data("{\"a\":1}\r\n".utf8)) == ["{\"a\":1}"])
    }

    @Test("A partial trailing line is held until flush")
    func partialTail() {
        var decoder = NDJSONLineDecoder()
        #expect(decoder.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(!decoder.isEmpty)
        #expect(decoder.flush() == "{\"a\":")
        #expect(decoder.flush() == nil)
    }

    @Test("An absurdly long line is dropped instead of growing without bound")
    func overlongLineIsDropped() {
        var decoder = NDJSONLineDecoder()
        let huge = Data(repeating: UInt8(ascii: "x"), count: NDJSONLineDecoder.maxLineBytes + 10)
        #expect(decoder.append(huge).isEmpty)
        #expect(decoder.append(Data("\nok\n".utf8)) == ["ok"])   // recovers on the next newline
        #expect(decoder.droppedLineCount == 1)
    }
}

@Suite("Backoff policy")
struct BackoffPolicyTests {

    @Test("Delays double from one second and cap at sixty")
    func doublesAndCaps() {
        var policy = BackoffPolicy(jitterFraction: { 0 })
        let delays = (0..<10).map { _ in policy.nextDelay().seconds }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60, 60])
        #expect(policy.attempt == 10)
    }

    @Test("Jitter only ever lengthens a delay")
    func jitterNeverShortens() {
        var policy = BackoffPolicy(jitterFraction: { 0.25 })
        #expect(policy.nextDelay().seconds == 1.25)
        #expect(policy.nextDelay().seconds == 2.5)

        var random = BackoffPolicy()
        for _ in 0..<50 {
            let before = random.attempt
            let delay = random.nextDelay().seconds
            let nominal = min(pow(2, Double(before)), 60)
            #expect(delay >= nominal)
            #expect(delay <= nominal * 1.25)
        }
    }

    @Test("Reset returns to the first delay")
    func reset() {
        var policy = BackoffPolicy(jitterFraction: { 0 })
        _ = policy.nextDelay(); _ = policy.nextDelay(); _ = policy.nextDelay()
        policy.reset()
        #expect(policy.attempt == 0)
        #expect(policy.nextDelay().seconds == 1)
    }

    @Test("Retry-After parsing accepts seconds and rejects nonsense")
    func retryAfterParsing() throws {
        func response(_ value: String?) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(
                url: URL(string: "https://lichess.org")!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: value.map { ["Retry-After": $0] }
            ))
        }
        #expect(try response("5").retryAfterDuration == .seconds(5))
        #expect(try response(" 120 ").retryAfterDuration == .seconds(120))
        #expect(try response(nil).retryAfterDuration == nil)
        #expect(try response("soon").retryAfterDuration == nil)
        let httpDate = try response("Wed, 21 Oct 2099 07:28:00 GMT").retryAfterDuration
        #expect((httpDate?.seconds ?? 0) > 0)
    }
}
