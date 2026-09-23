// follow-server — the push backend for Chess TV.
//
//   follow-server                         run the server, configured from the environment
//   follow-server --replay <round.pgn>    run the watcher over a recorded stream with APNs
//                 [--round <round.json>]  stubbed, and print the pushes it would have sent
//                 [--seed <seed.json>]
//   follow-server --check                 validate the environment and exit
//
// Configuration is environment-only (see Server/deploy/follow-server.env.example); nothing is
// passed as an argument, so a secret cannot end up in `ps`.

import Foundation
import FollowServer
import Logging

// Logs go to standard error so that `--replay`'s standard output is nothing but the JSON lines
// it prints. systemd's journal captures both either way.
LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}

let logger = ServerLog.make("cli")

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    follow-server
      (no arguments)              run the server, configured from the environment
      --replay <round.pgn>        replay a recorded PGN stream with APNs stubbed
        --round <round.json>      the round JSON that was current when it was recorded
        --seed <seed.json>        the device, preferences and follows to replay against
        --round-id <id>           the round id to attribute the stream to
      --check                     validate the environment and exit
    """)
    exit(0)
}

if arguments.contains("--check") {
    let configuration = ServerConfig.fromEnvironment()
    var problems = configuration.problems()
    // With swings on, prove the engine runs in this image — libraries, launcher, network and all
    // — before a deploy swaps it in. A short search, then the process is gone again.
    if problems.isEmpty, configuration.evalEnabled {
        var engineConfiguration = UCIConfiguration(executablePath: configuration.stockfishPath)
        engineConfiguration.hashMegabytes = configuration.stockfishHashMegabytes
        let engine = UCIProcess(configuration: engineConfiguration)
        do {
            let result = try await engine.search(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", movetimeMs: 300)
            let launcher = engineConfiguration.launcherPath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
            print("engine: depth \(result.depth) in 300 ms, score \(result.score.display), idle scheduling \(launcher ? "on" : "unavailable")")
        } catch {
            problems.append("the engine did not answer a search: \(error)")
        }
        await engine.stop()
    }
    if problems.isEmpty {
        print("ok: \(configuration.summary)")
        exit(0)
    }
    for problem in problems { print("problem: \(problem)") }
    exit(1)
}

if let pgnPath = value(after: "--replay") {
    do {
        let pgn = try String(contentsOfFile: pgnPath, encoding: .utf8)
        var detail: BroadcastRoundDetail?
        if let roundPath = value(after: "--round") {
            detail = try BroadcastDecoder.roundDetail(from: Data(contentsOf: URL(fileURLWithPath: roundPath)))
        }
        let seed = try value(after: "--seed").map { try ReplaySeed.load(contentsOf: URL(fileURLWithPath: $0)) } ?? ReplaySeed()
        let roundId = value(after: "--round-id") ?? detail?.round.id ?? "replay"

        let result = try await ReplayRunner().run(pgn: pgn, roundId: roundId, roundDetail: detail, seed: seed)
        FileHandle.standardError.write(Data("replayed \(result.events.count) events into \(result.pushes.count) pushes\n".utf8))
        let report = ReplayRunner.report(result)
        if !report.isEmpty { print(report) }
        exit(0)
    } catch {
        logger.critical("replay failed", metadata: ["error": .string(String(describing: error))])
        exit(1)
    }
}

do {
    try await FollowServerApp.run(configuration: .fromEnvironment())
} catch {
    logger.critical("server failed", metadata: ["error": .string(String(describing: error))])
    exit(1)
}
