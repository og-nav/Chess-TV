// The pinned game as an ordinary widget, in every family the phone offers.
//
// The Live Activity only exists while a game is being played and while the user has it pinned.
// This one draws the same snapshot out of the App Group whenever the user has put it on a Home
// Screen, the Lock Screen or in StandBy, and it keeps showing the last thing it knew after the
// activity has ended — a result is worth looking at for the rest of the evening.
//
// The timeline is deliberately small: one entry now, one entry a quarter of an hour out that
// stops claiming a clock is still running. WidgetKit's refresh budget is not something to spend
// on a chess clock, and the running clock is a `Text(timerInterval:)` which the system animates
// without waking anything.
import SwiftUI
import WidgetKit
import ChessCore
import ChessUI
import FollowKit

struct PinnedGameWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChessTVPinnedGame", provider: PinnedGameProvider()) { entry in
            PinnedGameWidgetView(entry: entry)
                .containerBackground(ChessTVPalette.ground, for: .widget)
        }
        .configurationDisplayName(Text("Pinned game", comment: "Widget name"))
        .description(Text("The broadcast game you pinned, with its clocks.", comment: "Widget description"))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

struct PinnedGameEntry: TimelineEntry {
    var date: Date
    var snapshot: PinnedGameSnapshot?
    /// True once the clocks in `snapshot` are too old to animate honestly.
    var clocksAreStale: Bool
}

struct PinnedGameProvider: TimelineProvider {

    /// After this long with no update, stop counting down: a game whose stream dropped an hour ago
    /// should not show a clock that has silently run to zero.
    private static let clocksGoStaleAfter: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> PinnedGameEntry {
        PinnedGameEntry(date: Date(), snapshot: PinnedGameSnapshot.placeholder, clocksAreStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (PinnedGameEntry) -> Void) {
        let stored = SharedStore.pinnedGame()
        completion(PinnedGameEntry(
            date: Date(),
            snapshot: stored ?? (context.isPreview ? PinnedGameSnapshot.placeholder : nil),
            clocksAreStale: false
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PinnedGameEntry>) -> Void) {
        let now = Date()
        let stored = SharedStore.pinnedGame()
        let staleAt = (stored?.state.asOf ?? now).addingTimeInterval(Self.clocksGoStaleAfter)

        var entries = [PinnedGameEntry(date: now, snapshot: stored, clocksAreStale: staleAt <= now)]
        if staleAt > now {
            entries.append(PinnedGameEntry(date: staleAt, snapshot: stored, clocksAreStale: true))
        }
        // `.never`: the app reloads these timelines itself every time the activity state changes,
        // which is the only moment anything here can have changed.
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct PinnedGameWidgetView: View {
    let entry: PinnedGameEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
        } else {
            EmptyPinnedView(family: family)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: PinnedGameSnapshot) -> some View {
        switch family {
        case .accessoryInline:
            Text(inlineText(snapshot))
        case .accessoryCircular:
            CircularPinnedView(snapshot: snapshot, stale: entry.clocksAreStale)
        case .accessoryRectangular:
            RectangularPinnedView(snapshot: snapshot, stale: entry.clocksAreStale)
        case .systemSmall:
            SmallPinnedView(snapshot: snapshot, stale: entry.clocksAreStale)
        default:
            WidePinnedView(snapshot: snapshot, stale: entry.clocksAreStale, large: family == .systemLarge)
        }
    }

    private func inlineText(_ snapshot: PinnedGameSnapshot) -> String {
        let names = "\(snapshot.whiteName) – \(snapshot.blackName)"
        if let result = ChessFormat.result(status: snapshot.state.status) { return "\(names) \(result)" }
        guard let move = ChessFormat.moveLabel(ply: snapshot.state.ply, san: snapshot.state.san, uci: snapshot.state.lastMove) else {
            return names
        }
        return "\(names) · \(move)"
    }
}

// MARK: - The families

private struct SmallPinnedView: View {
    let snapshot: PinnedGameSnapshot
    let stale: Bool

    var body: some View {
        VStack(spacing: 6) {
            MiniBoard(fen: snapshot.state.fen, lastMoveUCI: snapshot.state.lastMove, appearance: .widget)
            HStack(spacing: 4) {
                Text(snapshot.whiteName)
                    .font(.caption2)
                    .foregroundStyle(ChessTVPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 2)
                ResultChip(status: snapshot.state.status, compact: true)
            }
        }
    }
}

private struct WidePinnedView: View {
    let snapshot: PinnedGameSnapshot
    let stale: Bool
    let large: Bool

    var body: some View {
        HStack(spacing: 12) {
            MiniBoard(fen: snapshot.state.fen, lastMoveUCI: snapshot.state.lastMove, appearance: .widget)
                .frame(maxHeight: large ? 200 : 110)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: "\(snapshot.tourName) · \(snapshot.roundName)")
                    .font(.caption2)
                    .foregroundStyle(ChessTVPalette.muted)
                    .lineLimit(1)
                line(.black)
                line(.white)
                HStack(spacing: 6) {
                    if let move = snapshot.state.moveLabel { moveText(move) }
                    ResultChip(status: snapshot.state.status, compact: true)
                }
                if stale && !snapshot.state.isFinished {
                    Text("Clocks may be out of date", comment: "Widget note when the last update is old")
                        .font(.caption2)
                        .foregroundStyle(ChessTVPalette.muted)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func line(_ color: PieceColor) -> some View {
        PlayerLine(
            name: color == .white ? snapshot.whiteName : snapshot.blackName,
            title: color == .white ? snapshot.whiteTitle : snapshot.blackTitle,
            seconds: color == .white ? snapshot.state.whiteClock : snapshot.state.blackClock,
            deadline: stale ? nil : deadline(for: color),
            isToMove: !stale && snapshot.state.clockRunningFor == (color == .white ? "white" : "black")
        )
    }

    private func deadline(for color: PieceColor) -> Date? {
        let state = ChessGameActivityState(snapshot.state)
        return color == .white ? state.whiteDeadline : state.blackDeadline
    }

    private func moveText(_ move: String) -> some View {
        Text(move)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(ChessTVPalette.ink)
            .lineLimit(1)
    }
}

private struct RectangularPinnedView: View {
    let snapshot: PinnedGameSnapshot
    let stale: Bool

    var body: some View {
        HStack(spacing: 6) {
            MiniBoard(fen: snapshot.state.fen, lastMoveUCI: snapshot.state.lastMove, appearance: .widget)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.whiteName).font(.caption2).lineLimit(1)
                Text(snapshot.blackName).font(.caption2).lineLimit(1)
                if let result = ChessFormat.result(status: snapshot.state.status) {
                    Text(result).font(.caption2.weight(.semibold)).monospacedDigit()
                } else if let move = snapshot.state.moveLabel {
                    Text(move).font(.caption2).monospacedDigit().lineLimit(1)
                }
            }
        }
        // Accessory widgets are tinted by the system; no colours of our own here.
        .widgetAccentable()
    }
}

private struct CircularPinnedView: View {
    let snapshot: PinnedGameSnapshot
    let stale: Bool

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let result = ChessFormat.result(status: snapshot.state.status) {
                Text(result).font(.caption.weight(.semibold)).monospacedDigit()
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "square.grid.3x3.fill").font(.caption2)
                    Text(verbatim: "\(ChessFormat.moveNumber(ply: snapshot.state.ply))")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(Text(verbatim: "\(snapshot.whiteName) – \(snapshot.blackName)"))
    }
}

private struct EmptyPinnedView: View {
    let family: WidgetFamily

    var body: some View {
        VStack(spacing: 4) {
            if family != .accessoryInline && family != .accessoryCircular {
                Image(systemName: "pin.slash").foregroundStyle(ChessTVPalette.muted)
            }
            Text("No pinned game", comment: "Widget placeholder when nothing is pinned")
                .font(.caption2)
                .foregroundStyle(ChessTVPalette.muted)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Helpers

extension BoardAppearance {
    /// The App Group's colours, with coordinates off and the board always from White's side: a
    /// widget is glanced at, and a board that is sometimes upside down is a board you have to
    /// think about.
    static var widget: BoardAppearance {
        var appearance = BoardAppearance.fromAppGroup()
        appearance.showsCoordinates = false
        appearance.orientation = .white
        return appearance
    }
}

extension PinnedGameSnapshot {
    /// The gallery placeholder. A real opening position, so the widget gallery shows a board that
    /// looks like chess rather than a grid of empty squares.
    static let placeholder = PinnedGameSnapshot(
        roundId: "preview", gameId: "preview",
        tourName: "Tata Steel Masters", roundName: "Round 5",
        whiteName: "Carlsen", blackName: "Nepomniachtchi",
        whiteTitle: "GM", blackTitle: "GM",
        state: LiveActivityState(
            fen: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
            lastMove: "g8f6", san: "Nf6", ply: 6,
            whiteClock: 4_812, blackClock: 4_455, clockRunningFor: "white",
            status: "*", asOf: Date()
        )
    )
}
