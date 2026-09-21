import Foundation
import Testing
import ChessCore
@testable import LichessKit

@Suite("NDJSON event decoding")
struct EventDecodingTests {

    @Test("Every line of every recorded fixture decodes", arguments: Fixture.allCases)
    func everyLineDecodes(fixture: Fixture) throws {
        let lines = try fixture.lines
        #expect(!lines.isEmpty)
        let decoder = TVEventDecoder()
        for line in lines {
            let event = try decoder.decode(line: line)
            #expect(event != nil, "line did not decode: \(line)")
        }
        #expect(try fixture.events.count == lines.count)
    }

    @Test("Fixture line counts match the recordings")
    func fixtureShapes() throws {
        #expect(try Fixture.blitz.events.count == 13)
        #expect(try Fixture.bullet.events.count == 38)
        #expect(try Fixture.castling.events.count == 5)
    }

    @Test("The first two blitz events decode to exact values")
    func blitzExactValues() throws {
        let events = try Fixture.blitz.events

        #expect(events[0] == .featured(
            gameId: "n4EEhZrA",
            orientation: .white,
            players: [
                TVPlayer(name: "Niksss2023", title: "GM", rating: 2854, color: .white, secondsRemaining: 175),
                TVPlayer(name: "Pblu35", title: nil, rating: 2694, color: .black, secondsRemaining: 175),
            ],
            fen: "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QP2/2KR1B1q w - - 0 21"
        ))

        #expect(events[1] == .fen(
            fen: "r1b2rk1/pp2ppbp/6p1/4P3/6PN/2B4P/PPP1QPB1/2KR3q b - - 1 21",
            lastMove: "f1g2",
            whiteClock: 51,
            blackClock: 117
        ))
    }

    @Test("All five castling events decode to exact values")
    func castlingExactValues() throws {
        let events = try Fixture.castling.events
        #expect(events.count == 5)

        #expect(events[0] == .featured(
            gameId: "castle01",
            orientation: .white,
            players: [
                TVPlayer(name: "WhiteTester", title: nil, rating: 2000, color: .white, secondsRemaining: 180),
                TVPlayer(name: "BlackTester", title: "IM", rating: 2100, color: .black, secondsRemaining: 180),
            ],
            fen: "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 4 8"
        ))

        // King-to-rook castling encoding, white then black.
        #expect(events[1] == .fen(
            fen: "r3k2r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 b kq - 5 8",
            lastMove: "e1h1", whiteClock: 176, blackClock: 180
        ))
        #expect(events[2] == .fen(
            fen: "2kr3r/pppq1ppp/2npbn2/4p3/4P3/2NPBN2/PPPQ1PPP/R4RK1 w - - 6 9",
            lastMove: "e8a8", whiteClock: 176, blackClock: 174
        ))

        // Game change mid-stream, orientation flips to black.
        #expect(events[3] == .featured(
            gameId: "next0002",
            orientation: .black,
            players: [
                TVPlayer(name: "Alpha", title: nil, rating: 2300, color: .white, secondsRemaining: 60),
                TVPlayer(name: "Beta", title: nil, rating: 2280, color: .black, secondsRemaining: 60),
            ],
            fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        ))
        #expect(events[4] == .fen(
            fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            lastMove: "e2e4", whiteClock: 59, blackClock: 60
        ))
    }

    @Test("Unmodelled keys are ignored and optional fields tolerate absence")
    func toleratesLiveShapes() throws {
        let decoder = TVEventDecoder()
        // flair / patron / patronColor / user.id are present in live data and must be ignored;
        // title, rating and seconds may all be absent.
        let line = #"{"t":"featured","d":{"id":"abc12345","orientation":"black","players":[{"color":"white","user":{"name":"NoTitle","flair":"nature.deer","patron":true,"patronColor":3,"id":"notitle"}},{"color":"black","user":{"name":"Other","id":"other"},"rating":1500}],"fen":"8/8/8/8/8/8/8/8 w - - 0 1","extra":{"unknown":true}}}"#
        let event = try #require(try decoder.decode(line: line))
        #expect(event == .featured(
            gameId: "abc12345",
            orientation: .black,
            players: [
                TVPlayer(name: "NoTitle", title: nil, rating: nil, color: .white, secondsRemaining: nil),
                TVPlayer(name: "Other", title: nil, rating: 1500, color: .black, secondsRemaining: nil),
            ],
            fen: "8/8/8/8/8/8/8/8 w - - 0 1"
        ))
    }

    @Test("A fen event without clocks decodes with nil clocks")
    func fenWithoutClocks() throws {
        let event = try TVEventDecoder().decode(line: #"{"t":"fen","d":{"fen":"8/8/8/8/8/8/8/8 w - - 0 1"}}"#)
        #expect(event == .fen(fen: "8/8/8/8/8/8/8/8 w - - 0 1", lastMove: nil, whiteClock: nil, blackClock: nil))
    }

    @Test("Unknown event types are skipped, malformed lines throw")
    func unknownAndMalformed() throws {
        let decoder = TVEventDecoder()
        #expect(try decoder.decode(line: #"{"t":"crowd","d":{"watchers":12}}"#) == nil)
        #expect(throws: (any Error).self) { try decoder.decode(line: "{not json") }
        #expect(throws: (any Error).self) { try decoder.decode(line: #"{"t":"fen","d":{}}"#) }
    }
}

@Suite("Channels decoding")
struct ChannelsDecodingTests {

    @Test("The recorded channels.json decodes into all sixteen channels in order")
    func decodesFixture() throws {
        let summaries = try TVChannelsClient.decodeChannels(Fixture.channelsData)
        #expect(summaries.count == 16)
        #expect(summaries.map(\.channel) == TVChannel.allCases)

        let best = try #require(summaries.first { $0.channel == .best })
        #expect(best == TVChannelSummary(channel: .best, gameId: "n4EEhZrA", userName: "Niksss2023", rating: 2854))

        let chess960 = try #require(summaries.first { $0.channel == .chess960 })
        #expect(chess960 == TVChannelSummary(channel: .chess960, gameId: "Lx5JGS8S", userName: "Karavaha", rating: 1910))
    }

    @Test("Unknown channel keys are skipped, not fatal")
    func skipsUnknownChannels() throws {
        let json = #"{"blitz":{"user":{"name":"A","id":"a"},"rating":2000,"gameId":"g1","color":"white"},"martian":{"user":{"name":"B","id":"b"},"rating":1,"gameId":"g2","color":"black"}}"#
        let summaries = try TVChannelsClient.decodeChannels(Data(json.utf8))
        #expect(summaries.count == 1)
        #expect(summaries[0].channel == .blitz)
    }

    @Test("A channel with no rating and no user still decodes")
    func toleratesMissingFields() throws {
        let json = #"{"computer":{"gameId":"g9","color":"white"}}"#
        let summaries = try TVChannelsClient.decodeChannels(Data(json.utf8))
        #expect(summaries == [TVChannelSummary(channel: .computer, gameId: "g9", userName: "Anonymous", rating: nil)])
    }
}
