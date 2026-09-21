import Foundation
import LichessKit

/// Manual verification tool. Not part of the app; `print` is the point of it.
///
/// ```
/// lichess-probe [tv] <channel> [seconds]   stream a Lichess TV channel (default)
/// lichess-probe arenas                     list started and upcoming arenas
/// lichess-probe arena <id>                 one arena: summary, featured game, top 5
/// lichess-probe game <gameId> [seconds]    stream one game (history burst, then live)
/// lichess-probe broadcasts                 list active and upcoming broadcast rounds
/// lichess-probe round <roundId>            one round's boards
/// lichess-probe board <roundId> <gameId> [seconds]   follow one broadcast board (polling)
/// lichess-probe pgn <roundId> <gameId> [seconds]     follow one broadcast board via PGN (history)
/// ```
@main
struct Probe {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "tv"
        if !arguments.isEmpty { arguments.removeFirst() }

        switch command {
        case "arenas": await arenas()
        case "arena": await arena(id: arguments.first)
        case "game": await game(id: arguments.first, seconds: seconds(arguments.dropFirst().first))
        case "broadcasts": await broadcasts()
        case "round": await round(id: arguments.first)
        case "pgn": await pgn(roundId: arguments.first, gameId: arguments.dropFirst().first, seconds: seconds(arguments.dropFirst(2).first))
        case "board": await board(roundId: arguments.first, gameId: arguments.dropFirst().first, seconds: seconds(arguments.dropFirst(2).first))
        case "tv": await tv(channelName: arguments.first ?? "best", seconds: seconds(arguments.dropFirst().first))
        default: await tv(channelName: command, seconds: seconds(arguments.first))
        }
    }

    private static func seconds(_ argument: String?) -> Double { argument.flatMap(Double.init) ?? 30 }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    // MARK: - Arenas

    private static func arenas() async {
        do {
            let (started, upcoming) = try await ArenaClient().list()
            print("Started (\(started.count)):")
            for arena in started.prefix(12) { print("  " + row(arena)) }
            print("Upcoming (\(upcoming.count)):")
            for arena in upcoming.prefix(12) { print("  " + row(arena)) }
        } catch {
            fail("arena list failed: \(error)")
        }
    }

    private static func row(_ arena: ArenaSummary) -> String {
        let remaining = arena.secondsToFinish.map { " \($0)s left" } ?? ""
        return "\(arena.id.padded(10)) \(arena.perfKey.padded(11)) \(String(arena.nbPlayers).padded(5)) \(stamp(arena.startsAt))\(remaining)  \(arena.fullName)"
    }

    private static func arena(id: String?) async {
        guard let id else { fail("usage: lichess-probe arena <tournamentId>") }
        do {
            let detail = try await ArenaClient().detail(id: id)
            let summary = detail.summary
            print("\(summary.fullName)  [\(summary.id)]")
            print("  \(summary.perfKey)/\(summary.variantKey)  \(summary.nbPlayers) players  \(summary.minutes) min  starts \(stamp(summary.startsAt))")
            print("  started=\(summary.isStarted) finished=\(summary.isFinished) secondsToFinish=\(summary.secondsToFinish.map(String.init) ?? "-")")
            if let featured = detail.featured {
                print("  featured \(featured.gameId)  lm=\(featured.lastMove ?? "-")")
                print("    white \(featured.white.name) \(featured.white.rating.map(String.init) ?? "-") rank=\(featured.white.rank.map(String.init) ?? "-") \(featured.white.secondsRemaining.map { "\($0)s" } ?? "-")")
                print("    black \(featured.black.name) \(featured.black.rating.map(String.init) ?? "-") rank=\(featured.black.rank.map(String.init) ?? "-") \(featured.black.secondsRemaining.map { "\($0)s" } ?? "-")")
                print("    \(featured.fen)")
            } else {
                print("  featured: none")
            }
            for standing in detail.standings {
                print("  #\(standing.rank) \(standing.title.map { "\($0) " } ?? "")\(standing.name) \(standing.rating.map(String.init) ?? "-") — \(standing.score)\(standing.onStreak ? " fire" : "")\(standing.withdrawn ? " withdrawn" : "")")
            }
        } catch {
            fail("arena detail failed: \(error)")
        }
    }

    // MARK: - Broadcasts

    private static func broadcasts() async {
        do {
            let (active, upcoming) = try await BroadcastClient().top()
            print("Active (\(active.count)):")
            for tour in active.prefix(12) { print("  " + row(tour)) }
            print("Upcoming (\(upcoming.count)):")
            for tour in upcoming.prefix(12) { print("  " + row(tour)) }
        } catch {
            fail("broadcast list failed: \(error)")
        }
    }

    private static func row(_ tour: BroadcastTournament) -> String {
        let starts = tour.roundStartsAt.map(stamp) ?? "-"
        return "\(tour.roundId.padded(10)) t\(tour.tier.map(String.init) ?? "-") \(tour.roundOngoing ? "LIVE" : "    ") \(starts)  \(tour.name) — \(tour.roundName)\(tour.location.map { "  (\($0))" } ?? "")"
    }

    private static func round(id: String?) async {
        guard let id else { fail("usage: lichess-probe round <roundId>") }
        do {
            let (round, boards) = try await BroadcastClient().round(id: id)
            print("\(round.name) — \(round.roundName)  [\(round.roundId)] ongoing=\(round.roundOngoing)")
            print("  format=\(round.format ?? "-") location=\(round.location ?? "-") tier=\(round.tier.map(String.init) ?? "-")")
            print("  \(boards.count) boards:")
            for board in boards {
                let clocks = board.players.map { $0.clockSeconds.map { "\($0)s" } ?? "-" }.joined(separator: "/")
                print("    \(board.gameId.padded(10)) \(board.status.padded(4)) \(clocks.padded(14)) \(board.name)")
                print("      \(board.fen)")
            }
        } catch {
            fail("broadcast round failed: \(error)")
        }
    }

    private static func board(roundId: String?, gameId: String?, seconds: Double) async {
        guard let roundId, let gameId else { fail("usage: lichess-probe board <roundId> <gameId> [seconds]") }
        let stream = BroadcastBoardStream()
        print("Following board \(gameId) of round \(roundId) for \(Int(seconds))s…")
        await drain(
            events: stream.events(roundId: roundId, gameId: gameId),
            states: stream.connectionStates,
            seconds: seconds,
            finish: { stream.finish() }
        )
    }

    // MARK: - Single game

    private static func game(id: String?, seconds: Double) async {
        guard let id else { fail("usage: lichess-probe game <gameId> [seconds]") }
        let stream = GameStream()
        print("Streaming game \(id) for \(Int(seconds))s… (history burst first, then live moves)")
        await drainSourced(
            events: stream.sourcedEvents(gameId: id),
            states: stream.connectionStates,
            seconds: seconds,
            finish: {
                if let termination = stream.lastTermination {
                    print("[over] \(termination.status.name) winner=\(termination.status.winner.map(String.init(describing:)) ?? "-")")
                }
                stream.finish()
            }
        )
    }

    // MARK: - Broadcast board over PGN

    private static func pgn(roundId: String?, gameId: String?, seconds: Double) async {
        guard let roundId, let gameId else { fail("usage: lichess-probe pgn <roundId> <gameId> [seconds]") }
        let stream = BroadcastPGNStream()
        print("Following board \(gameId) of round \(roundId) over PGN for \(Int(seconds))s…")
        await drainSourced(
            events: stream.sourcedEvents(roundId: roundId, gameId: gameId),
            states: stream.connectionStates,
            seconds: seconds,
            finish: {
                if let result = stream.lastResult { print("[over] result=\(result.result)") }
                stream.finish()
            }
        )
    }

    // MARK: - TV (original behaviour)

    private static func tv(channelName: String, seconds: Double) async {
        guard let channel = TVChannel(rawValue: channelName) else {
            fail("Unknown channel '\(channelName)'. One of: \(TVChannel.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        print("Channels:")
        do {
            for summary in try await TVChannelsClient().currentGames() {
                print("  \(summary.channel.displayName.padded(14)) \(summary.gameId)  \(summary.userName) (\(summary.rating.map(String.init) ?? "-"))")
            }
        } catch {
            print("  channels request failed: \(error)")
        }

        let feed = TVFeedStream()
        print("\nStreaming \(channel.displayName) for \(Int(seconds))s…")
        await drain(
            events: feed.events(for: channel),
            states: feed.connectionStates,
            seconds: seconds,
            finish: { feed.finish() }
        )
    }

    // MARK: - Shared plumbing

    private static func drain(
        events stream: AsyncThrowingStream<TVEvent, Error>,
        states: AsyncStream<ConnectionState>,
        seconds: Double,
        finish: @escaping @Sendable () -> Void
    ) async {
        let stateTask = Task {
            for await state in states { print("[state] \(state)") }
        }
        let eventTask = Task {
            do {
                for try await event in stream { print(describe(event)) }
                print("[done] stream finished")
            } catch {
                print("[error] \(error)")
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        eventTask.cancel()
        _ = await eventTask.result
        finish()
        stateTask.cancel()
        print("Done.")
    }

    /// Like `drain`, but printing whether each event is replayed history or a live move, and
    /// counting the history burst.
    private static func drainSourced(
        events stream: AsyncThrowingStream<SourcedEvent, Error>,
        states: AsyncStream<ConnectionState>,
        seconds: Double,
        finish: @escaping @Sendable () -> Void
    ) async {
        let stateTask = Task {
            for await state in states { print("[state] \(state)") }
        }
        let eventTask = Task { () -> (history: Int, live: Int) in
            var history = 0
            var live = 0
            do {
                for try await sourced in stream {
                    if sourced.isHistorical { history += 1 } else { live += 1 }
                    if case .fen = sourced.event, sourced.isHistorical {
                        // The burst can be hundreds of plies; one line each is enough.
                        print("[hist \(history)]  " + describe(sourced.event))
                    } else {
                        print("[live]     " + describe(sourced.event))
                    }
                }
                print("[done] stream finished")
            } catch {
                print("[error] \(error)")
            }
            return (history, live)
        }
        try? await Task.sleep(for: .seconds(seconds))
        eventTask.cancel()
        let counts = await eventTask.value
        print("[burst] \(counts.history) historical events replayed, \(counts.live) live")
        finish()
        stateTask.cancel()
        print("Done.")
    }

    private static func describe(_ event: TVEvent) -> String {
        switch event {
        case .featured(let gameId, let orientation, let players, let fen):
            var lines = ["[featured] \(gameId) orientation=\(orientation)"]
            for player in players {
                lines.append("           \(player.color) \(player.title.map { "\($0) " } ?? "")\(player.name) \(player.rating.map(String.init) ?? "-") \(player.secondsRemaining.map { "\($0)s" } ?? "-")")
            }
            lines.append("           \(fen)")
            return lines.joined(separator: "\n")
        case .fen(let fen, let lastMove, let whiteClock, let blackClock):
            return "[fen]      lm=\(lastMove ?? "-") wc=\(whiteClock.map(String.init) ?? "-") bc=\(blackClock.map(String.init) ?? "-")  \(fen)"
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
