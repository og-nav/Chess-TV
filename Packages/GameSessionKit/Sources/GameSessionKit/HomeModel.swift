// The home screen's data: what each shelf shows, in what order, refreshed on a timer.
//
// The ordering and the status lines are pure functions on `HomeShelves` so ChessTVTests can
// check them without a network.
import Foundation
import LichessKit

// MARK: - Shelf contents

/// One arena card: the summary plus which bucket it came from.
public struct ArenaShelfItem: Identifiable, Equatable, Sendable {
    public let summary: ArenaSummary
    public let isLive: Bool
    public var id: String { summary.id }
}

/// Ordering, filtering and the small bits of text the cards show.
public enum HomeShelves {

    /// Live arenas first, most players first, then the soonest upcoming ones.
    public static let liveArenaLimit = 12
    public static let upcomingArenaLimit = 8
    /// Broadcasts below this tier are club-level noise on a TV.
    public static let minimumEventTier = 3
    public static let eventLimit = 20

    public static func arenaItems(started: [ArenaSummary], upcoming: [ArenaSummary]) -> [ArenaShelfItem] {
        let live = started
            .filter { !$0.isFinished }
            .sorted { $0.nbPlayers == $1.nbPlayers ? $0.id < $1.id : $0.nbPlayers > $1.nbPlayers }
            .prefix(liveArenaLimit)
            .map { ArenaShelfItem(summary: $0, isLive: true) }
        let next = upcoming
            .filter { !$0.isFinished }
            .sorted { $0.startsAt == $1.startsAt ? $0.id < $1.id : $0.startsAt < $1.startsAt }
            .prefix(upcomingArenaLimit)
            .map { ArenaShelfItem(summary: $0, isLive: false) }
        return live + next
    }

    /// Rounds being played first, then the rest of the active broadcasts, then the upcoming ones.
    public static func eventItems(active: [BroadcastTournament], upcoming: [BroadcastTournament]) -> [BroadcastTournament] {
        let keep: (BroadcastTournament) -> Bool = { ($0.tier ?? 0) >= minimumEventTier }
        let ongoing = active.filter { keep($0) && $0.roundOngoing }
        let rest = active.filter { keep($0) && !$0.roundOngoing }
        let later = upcoming.filter(keep)
        return Array((ongoing + rest + later).prefix(eventLimit))
    }

    /// The Lichess TV shelf order: the seven headline channels, then everything else.
    public static var channelOrder: [TVChannel] { ChannelOrder.all }

    // MARK: - Status lines

    /// "Ends in 42m" / "Ends in 1h 05m" / "Finishing" for a live arena, from `startsAt + minutes`.
    /// The arena list endpoint sends no `secondsToFinish`, so this is the only way to say it.
    public static func endsIn(startsAt: Date, minutes: Int, now: Date) -> String {
        let remaining = startsAt.addingTimeInterval(Double(minutes) * 60).timeIntervalSince(now)
        guard remaining > 30 else { return "Finishing" }
        return "Ends in " + duration(seconds: remaining)
    }

    /// "Starts in 12m" while it is close, otherwise the local clock time.
    public static func startsIn(startsAt: Date, now: Date) -> String {
        let remaining = startsAt.timeIntervalSince(now)
        if remaining <= 30 { return "Starting" }
        if remaining < 3600 { return "Starts in " + duration(seconds: remaining) }
        return "Starts at " + time(startsAt)
    }

    /// "42m", "1h 05m", "2d". Rounded up, so a card never says "0m" while it is still running.
    public static func duration(seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        if total >= 86_400 { return "\(total / 86_400)d" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// The local short time, e.g. "7:30 PM".
    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The badge under an event card: "Live", "Round 3 · starts 7:30 PM", or the round name.
    public static func eventStatus(_ tournament: BroadcastTournament, now: Date) -> String {
        if tournament.roundOngoing { return "Live" }
        guard let startsAt = tournament.roundStartsAt else { return tournament.roundName }
        let day = Calendar.current.isDateInToday(startsAt)
            ? time(startsAt)
            : startsAt.formatted(date: .abbreviated, time: .shortened)
        return "\(tournament.roundName) \u{00B7} starts \(day)"
    }
}

// MARK: - Titles

/// The one place that spells a source for the GameScreen header.
public enum SourceTitle {
    public static func text(for source: GameSource) -> String {
        switch source {
        case .tvChannel(let channel): "\(channel.displayName) \u{00B7} Lichess TV"
        case .arena: "Arena \u{00B7} Lichess"
        case .broadcastBoard: "Broadcast"
        }
    }

    public static func arena(_ summary: ArenaSummary) -> String { "\(summary.fullName) \u{00B7} Lichess" }

    public static func board(tournament: String, round: String, boardNumber: Int?) -> String {
        let board = boardNumber.map { " \u{00B7} Board \($0)" } ?? ""
        return "\(tournament) \u{00B7} \(round)\(board)"
    }
}

// MARK: - Loading

/// What a shelf knows right now. There is never a blank shelf: it is loading, loaded or broken.
public enum LoadState<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)

    public var value: Value? { if case .loaded(let value) = self { return value }; return nil }
}

/// Owns the three shelf fetches and re-runs them while the home screen is on screen.
@Observable
@MainActor
public final class HomeModel {

    public private(set) var channels: LoadState<[TVChannelSummary]> = .loading
    public private(set) var arenas: LoadState<[ArenaShelfItem]> = .loading
    public private(set) var events: LoadState<[BroadcastTournament]> = .loading

    @ObservationIgnored private let channelsClient: TVChannelsClient
    @ObservationIgnored private let arenaClient: ArenaClient
    @ObservationIgnored private let broadcastClient: BroadcastClient
    @ObservationIgnored private let refreshInterval: Duration
    /// Launch-to-content timing: when `run()` first started, and which shelves have reported.
    @ObservationIgnored private var firstRun: ContinuousClock.Instant?
    @ObservationIgnored private var shelvesTimed: Set<String> = []

    public init(
        channelsClient: TVChannelsClient = TVChannelsClient(),
        arenaClient: ArenaClient = ArenaClient(),
        broadcastClient: BroadcastClient = BroadcastClient(),
        refreshInterval: Duration = .seconds(60)
    ) {
        self.channelsClient = channelsClient
        self.arenaClient = arenaClient
        self.broadcastClient = broadcastClient
        self.refreshInterval = refreshInterval
    }

    /// Runs until the home screen goes away (SwiftUI cancels the `.task`). Each shelf has its own
    /// loop, so a failing endpoint never holds up the other two.
    public func run() async {
        if firstRun == nil { firstRun = .now }
        async let channels: Void = channelLoop()
        async let arenas: Void = arenaLoop()
        async let events: Void = eventLoop()
        _ = await (channels, arenas, events)
    }

    private func channelLoop() async {
        while !Task.isCancelled {
            await loadChannels()
            guard await nap() else { return }
        }
    }

    private func arenaLoop() async {
        while !Task.isCancelled {
            await loadArenas()
            guard await nap() else { return }
        }
    }

    private func eventLoop() async {
        while !Task.isCancelled {
            await loadEvents()
            guard await nap() else { return }
        }
    }

    /// Waits for the next refresh; false once the screen has gone away.
    private func nap() async -> Bool {
        do { try await Task.sleep(for: refreshInterval); return true } catch { return false }
    }

    /// The summary for one channel, for the "<user> · <rating>" line.
    public func summary(for channel: TVChannel) -> TVChannelSummary? {
        channels.value?.first { $0.channel == channel }
    }

    /// The live arena with this id, used to decide whether "Continue watching" is still offerable.
    public func liveArena(id: String) -> ArenaSummary? {
        arenas.value?.first { $0.isLive && $0.id == id }?.summary
    }

    /// A request that ended because its task was cancelled, whichever layer reported it.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// The first time each shelf has content, one `timing` line: how long after the home screen
    /// started loading it appeared. Later refreshes are not timed.
    private func noteShelfLoaded(_ shelf: String) {
        guard let firstRun, !shelvesTimed.contains(shelf) else { return }
        shelvesTimed.insert(shelf)
        timingLog.notice("home \(shelf, privacy: .public) +\(OpenTiming.millis(.now - firstRun))ms")
    }

    private func loadChannels() async {
        do {
            let summaries = try await channelsClient.currentGames()
            channels = .loaded(summaries)
            noteShelfLoaded("channels")
            appLog.debug("Home: \(summaries.count) TV channels")
        } catch {
            if Self.isCancellation(error) { return }   // the screen went away mid-request: not a failure
            appLog.error("Home: channels failed: \(String(describing: error), privacy: .public)")
            if channels.value == nil { channels = .failed("Couldn\u{2019}t load channels \u{00B7} retrying") }
        }
    }

    private func loadArenas() async {
        do {
            let (started, upcoming) = try await arenaClient.list()
            arenas = .loaded(HomeShelves.arenaItems(started: started, upcoming: upcoming))
            noteShelfLoaded("arenas")
        } catch {
            if Self.isCancellation(error) { return }   // the screen went away mid-request: not a failure
            appLog.error("Home: arenas failed: \(String(describing: error), privacy: .public)")
            if arenas.value == nil { arenas = .failed("Couldn\u{2019}t load arenas \u{00B7} retrying") }
        }
    }

    private func loadEvents() async {
        do {
            let (active, upcoming) = try await broadcastClient.top()
            events = .loaded(HomeShelves.eventItems(active: active, upcoming: upcoming))
            noteShelfLoaded("events")
        } catch {
            if Self.isCancellation(error) { return }   // the screen went away mid-request: not a failure
            appLog.error("Home: broadcasts failed: \(String(describing: error), privacy: .public)")
            if events.value == nil { events = .failed("Couldn\u{2019}t load events \u{00B7} retrying") }
        }
    }
}
