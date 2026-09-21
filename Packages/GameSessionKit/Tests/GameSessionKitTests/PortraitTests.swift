// Where a broadcast player's face comes from, and what must not take it away again.
import Testing
import Foundation
import ChessCore
import LichessKit
@testable import GameSessionKit

/// A FIDE lookup the test can make fail the way Lichess's anonymous rate limit does.
///
/// `failAfter` is a count rather than a flag because the interesting order is "it worked, then it
/// stopped working": `GameSession` looks both players up twice, once from the destination and
/// once when the opening round read lands, and the second attempt must not undo the first.
private final class StubFIDE: FIDEPlayerLooking, @unchecked Sendable {   // @unchecked: lock-guarded
    private let lock = NSLock()
    private let answers: [Int: FIDEPlayer]
    private let failAfter: Int
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    init(answers: [Int: FIDEPlayer] = [:], failAfter: Int = .max) {
        self.answers = answers
        self.failAfter = failAfter
    }

    func player(fideId: Int) async throws -> FIDEPlayer? {
        let index = lock.withLock { calls += 1; return calls }
        if index > failAfter { throw LichessError.rateLimited(retryAfter: nil) }
        return answers[fideId]
    }
}

/// A round read that answers at once with the boards the test handed it.
private struct StubRounds: BroadcastRoundFetching {
    let boards: [BroadcastBoard]

    func round(id: String) async throws -> (round: BroadcastTournament, boards: [BroadcastBoard]) {
        (BroadcastTournament(tourId: "tour", name: "Test Open", tier: nil, roundId: id,
                             roundName: "Round 1", roundOngoing: true, roundStartsAt: nil,
                             format: nil, location: nil, isActive: true), boards)
    }
}

@Suite("Broadcast portraits")
@MainActor
struct PortraitTests {

    private static let whiteFideId = 1_503_014
    private static let blackFideId = 2_020_009
    private static let source = GameSource.broadcastBoard(roundId: "round", gameId: "game")

    private static let roundPhoto = PlayerPhoto(
        smallURL: URL(string: "https://image.lichess1.org/display?w=100&path=white.webp"),
        mediumURL: URL(string: "https://image.lichess1.org/display?w=500&path=white.webp"),
        credit: "Round Photographer"
    )

    private static let fideRecord = FIDEPlayer(
        id: whiteFideId, name: "Carlsen, Magnus", federation: "NOR", title: "GM",
        photoMediumURL: URL(string: "https://image.lichess1.org/display?w=500&path=fide.webp"),
        photoCredit: "FIDE Photographer"
    )

    private func board(whitePhoto: PlayerPhoto? = nil, blackPhoto: PlayerPhoto? = nil) -> BroadcastBoard {
        BroadcastBoard(
            gameId: "game", name: "Alice \u{2014} Bob",
            fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
            lastMove: "e2e4", status: "*",
            players: [
                BroadcastPlayer(name: "Alice", title: "GM", rating: 2700, federation: "NOR",
                                clockMs: 60_000, fideId: Self.whiteFideId, photo: whitePhoto),
                BroadcastPlayer(name: "Bob", title: "GM", rating: 2800, federation: "USA",
                                clockMs: 60_000, fideId: Self.blackFideId, photo: blackPhoto),
            ]
        )
    }

    private func makeSession(fide: StubFIDE, boards: [BroadcastBoard]) -> GameSession {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ChessTVTests-\(UUID().uuidString)")!)
        settings.sounds = false
        settings.tournamentAlerts = false
        settings.engineEnabled = false
        return GameSession(settings: settings, streamer: FakeStreamer(), arenas: FakeArenas(),
                           broadcasts: StubRounds(boards: boards), fidePlayers: fide)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The regression this file exists for. A board opened without FIDE ids — a push, a deep link,
    /// a Continue-watching row — has only the round read to go on, and if the FIDE endpoint is
    /// rate limited that read used to be the end of it: initials for the rest of the game. The
    /// round payload carries the pictures itself, so the face arrives with the board either way.
    @Test("A round's own photos show when the FIDE lookup fails")
    func photosSurviveAFailedLookup() async throws {
        let fide = StubFIDE(failAfter: 0)      // every lookup is rate limited
        let session = makeSession(fide: fide, boards: [board(whitePhoto: Self.roundPhoto)])
        session.open(GameDestination(source: Self.source))

        #expect(await eventually { session.portraitURL(for: .white) != nil })
        #expect(session.portraitURL(for: .white) == Self.roundPhoto.mediumURL)
        #expect(session.photoCredit(for: .white) == "Round Photographer")
        // Black has no picture in the round book and no FIDE record either: placeholder, and no
        // credit for a photograph nobody is looking at.
        #expect(session.portraitURL(for: .black) == nil)
        #expect(session.photoCredit(for: .black) == nil)
        session.close()
    }

    /// The FIDE record wins when there is one, and it brings its own photographer with it.
    @Test("The FIDE record is preferred over the round's copy")
    func fideRecordWins() async throws {
        let record = FIDEPlayer(
            id: Self.whiteFideId, name: "Carlsen, Magnus", federation: "NOR", title: "GM",
            photoSmallURL: URL(string: "https://image.lichess1.org/display?w=100&path=fide.webp"),
            photoMediumURL: URL(string: "https://image.lichess1.org/display?w=500&path=fide.webp"),
            photoCredit: "FIDE Photographer"
        )
        let fide = StubFIDE(answers: [Self.whiteFideId: record])
        let session = makeSession(fide: fide, boards: [board(whitePhoto: Self.roundPhoto)])
        session.open(GameDestination(source: Self.source))

        #expect(await eventually { session.portraitURL(for: .white) == record.photoMediumURL })
        #expect(session.photoCredit(for: .white) == "FIDE Photographer")
        session.close()
    }

    /// Opening a board used to ask twice: once from the destination, then again when the round
    /// read landed. The second call cancelled the first mid-flight, so the first answer was
    /// thrown away and a rate-limited second attempt left the panel with initials for the rest of
    /// the game. Asking for the same two ids again is now a no-op.
    @Test("The round read does not re-ask for ids the destination already supplied")
    func theSamePairIsNotAskedTwice() async throws {
        let record = Self.fideRecord
        let fide = StubFIDE(answers: [Self.whiteFideId: record], failAfter: 2)
        let session = makeSession(fide: fide, boards: [board()])
        session.open(GameDestination(source: Self.source, title: "Test Open \u{00B7} Board 1",
                                     whiteFideId: Self.whiteFideId, blackFideId: Self.blackFideId))

        #expect(await eventually { session.portraitURL(for: .white) != nil })
        // Give the round read time to land and call loadPortraits a second time.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fide.callCount == 2, "one lookup per player, not one per call site")
        #expect(session.portraitURL(for: .white) == record.photoMediumURL)
        #expect(session.fidePlayer(for: .white)?.name == "Carlsen, Magnus")
        session.close()
    }

    /// When the round read *does* bring an id the destination did not have, the lookup starts
    /// again — and a failure in that second pass must not wipe the record the first pass found.
    @Test("A later failed lookup does not erase a portrait already found")
    func failedLookupDoesNotEraseAPortrait() async throws {
        let record = Self.fideRecord
        // Only the destination's single white lookup succeeds; the pair asked for afterwards is
        // rate limited, the way Lichess answers a client that has just read a big round.
        let fide = StubFIDE(answers: [Self.whiteFideId: record], failAfter: 1)
        let session = makeSession(fide: fide, boards: [board()])
        session.open(GameDestination(source: Self.source, title: "Test Open \u{00B7} Board 1",
                                     whiteFideId: Self.whiteFideId))

        #expect(await eventually { session.portraitURL(for: .white) != nil })
        // The round read brings black's id, so a second lookup does start — and fails.
        #expect(await eventually { fide.callCount >= 2 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(session.portraitURL(for: .white) == record.photoMediumURL)
        #expect(session.fidePlayer(for: .white)?.name == "Carlsen, Magnus")
        #expect(session.fidePlayer(for: .black) == nil)
        // White was asked for once, by the destination; only black is asked for afterwards.
        #expect(fide.callCount == 2)
        session.close()
    }

    /// The board list hands its pictures to the game screen, so the face is there before any
    /// request of the game screen's own finishes.
    @Test("A destination carries the board list's photos")
    func destinationCarriesPhotos() {
        let preview = GamePreview(board: board(whitePhoto: Self.roundPhoto), receivedAt: .now, clocksRunning: true)
        let fromPreview = GameDestination(source: Self.source, preview: preview)
        #expect(fromPreview.whitePhoto == Self.roundPhoto)
        #expect(fromPreview.blackPhoto == nil)

        let explicit = GameDestination(source: Self.source, whitePhoto: Self.roundPhoto)
        #expect(explicit.whitePhoto == Self.roundPhoto)
    }
}
