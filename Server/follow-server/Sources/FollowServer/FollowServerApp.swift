// Wiring. Everything the process runs is assembled here and nowhere else.

import AsyncHTTPClient
import Foundation
import FollowKit
import Hummingbird
import Logging
import NIOCore

public enum FollowServerApp {

    /// Runs the server until the task is cancelled.
    ///
    /// Three things run side by side: the HTTP API, the round watcher (which is itself a poll
    /// plus one stream per watched round), and the outbox worker. If any of them stops, they all
    /// do — a server that is answering requests but not watching chess is worse than one that is
    /// visibly down.
    public static func run(configuration: ServerConfig) async throws {
        let logger = ServerLog.make("main", level: configuration.logLevel)

        let problems = configuration.problems()
        guard problems.isEmpty else {
            for problem in problems { logger.critical("configuration", metadata: ["problem": .string(problem)]) }
            throw ServerStartupError.badConfiguration(problems)
        }
        logger.info("starting", metadata: ["configuration": .string(configuration.summary)])

        let store = try await FollowStore.open(path: configuration.databasePath, logger: ServerLog.make("store", level: configuration.logLevel))

        var httpConfiguration = HTTPClient.Configuration()
        // Long enough for a quiet classical board to stay connected, short enough that a dead
        // connection is noticed within a move.
        httpConfiguration.timeout = HTTPClient.Configuration.Timeout(connect: .seconds(10), read: .minutes(10))
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)

        let source = LichessBroadcastClient(configuration: configuration, client: httpClient, logger: ServerLog.make("lichess", level: configuration.logLevel))

        let delivery: any PushDelivering
        var apns: APNSPushDelivery?
        if configuration.apnsEnabled {
            let sender = try APNSPushDelivery(configuration: configuration, logger: ServerLog.make("apns", level: configuration.logLevel))
            apns = sender
            delivery = sender
        } else {
            // No key yet: the server still watches, still decides, still writes the outbox. What
            // it would have sent is in the database and in the log, which is what a first deploy
            // wants anyway.
            logger.warning("APNs is not configured; pushes will be recorded, not delivered")
            delivery = RecordingDelivery()
        }

        let outbox = OutboxWorker(store: store, delivery: delivery, configuration: configuration, logger: ServerLog.make("outbox", level: configuration.logLevel))
        let pipeline = FollowPipeline(store: store, outbox: outbox, logger: ServerLog.make("pipeline", level: configuration.logLevel))
        let coordinator = WatchCoordinator(
            store: store,
            source: source,
            pipeline: pipeline,
            configuration: configuration,
            logger: ServerLog.make("coordinator", level: configuration.logLevel)
        )

        let api = FollowAPI(
            store: store,
            configuration: configuration,
            logger: ServerLog.make("api", level: configuration.logLevel),
            watchSetChanged: { await coordinator.requestPoll() },
            health: {
            await ServerHealth(
                ok: true,
                roundsWatched: coordinator.watchedRoundCount,
                roundsScheduled: (try? await store.scheduledRoundCount()) ?? 0,
                lastLichessEventAt: coordinator.lastEventAt
            )
        })

        var applicationLogger = ServerLog.make("http", level: configuration.logLevel)
        applicationLogger.logLevel = configuration.logLevel
        let application = Application(
            router: api.router(),
            configuration: ApplicationConfiguration(
                address: .hostname(configuration.host, port: configuration.port),
                serverName: "follow-server"
            ),
            logger: applicationLogger
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await application.runService() }
                group.addTask { await coordinator.run() }
                group.addTask { await outbox.run() }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            logger.critical("server stopped", metadata: ["error": .string(String(describing: type(of: error)))])
            await stop(apns: apns, store: store, httpClient: httpClient, logger: logger)
            throw error
        }
        await stop(apns: apns, store: store, httpClient: httpClient, logger: logger)
    }

    /// One shutdown path, used whether the group ended cleanly or threw.
    private static func stop(apns: APNSPushDelivery?, store: FollowStore, httpClient: HTTPClient, logger: Logger) async {
        await apns?.shutdown()
        try? await httpClient.shutdown()
        await store.close()
        logger.info("stopped")
    }
}

public enum ServerStartupError: Error, Sendable, Equatable {
    case badConfiguration([String])
}
