// The watch's Smart Stack widget.
//
// It draws the pinned game out of the watch's own App Group — the snapshot `WatchSyncStore` wrote
// the last time the phone synced. It does no network: a widget that polls Lichess from a wrist is
// exactly the traffic the plan says not to make, and the Smart Stack's budget would not support
// it anyway.
//
// This is deliberately *not* the mirrored Live Activity. watchOS mirrors that on its own from the
// phone while a game is pinned and being played; this widget is what remains between games, and
// what a person gets when they put Chess TV in the stack themselves.
import SwiftUI
import WidgetKit
import ChessCore
import ChessUI
import FollowKit

@main
struct ChessTVWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchPinnedGameWidget()
    }
}

struct WatchPinnedGameWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchPinnedWidget.kind, provider: WatchPinnedProvider()) { entry in
            WatchPinnedView(entry: entry)
                .containerBackground(ChessTVPalette.ground, for: .widget)
        }
        .configurationDisplayName(Text("Pinned game", comment: "Watch widget name"))
        .description(Text("The game pinned on your iPhone.", comment: "Watch widget description"))
        .supportedFamilies(Self.families)
    }

    /// `.accessoryCorner` exists only on watchOS. This target is watchOS-only, but it is embedded
    /// in the watch app which is in turn embedded in the phone app, and a phone build that reaches
    /// this file with the iOS SDK fails on that one case rather than skipping the target. The
    /// guard costs nothing and keeps the mobile scheme compiling.
    private static var families: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryRectangular, .accessoryCircular, .accessoryInline, .accessoryCorner]
        #else
        [.accessoryRectangular, .accessoryCircular, .accessoryInline]
        #endif
    }
}

struct WatchPinnedEntry: TimelineEntry {
    var date: Date
    var pinned: PinnedGameSnapshot?
    var clocksAreStale: Bool
}

struct WatchPinnedProvider: TimelineProvider {

    /// After this long the clocks stop counting down. A wrist widget that quietly ran a clock to
    /// zero because the phone went away would be worse than one that says nothing.
    private static let clocksGoStaleAfter: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> WatchPinnedEntry {
        WatchPinnedEntry(date: Date(), pinned: .watchPlaceholder, clocksAreStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchPinnedEntry) -> Void) {
        let stored = WatchSnapshot.read()?.pinned
        completion(WatchPinnedEntry(
            date: Date(),
            pinned: stored ?? (context.isPreview ? .watchPlaceholder : nil),
            clocksAreStale: false
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchPinnedEntry>) -> Void) {
        let now = Date()
        let pinned = WatchSnapshot.read()?.pinned
        let staleAt = (pinned?.state.asOf ?? now).addingTimeInterval(Self.clocksGoStaleAfter)

        var entries = [WatchPinnedEntry(date: now, pinned: pinned, clocksAreStale: staleAt <= now)]
        if staleAt > now {
            entries.append(WatchPinnedEntry(date: staleAt, pinned: pinned, clocksAreStale: true))
        }
        // The watch app reloads this whenever a sync lands; there is nothing else that can change it.
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct WatchPinnedView: View {
    let entry: WatchPinnedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let pinned = entry.pinned {
            content(pinned)
        } else {
            empty
        }
    }

    @ViewBuilder
    private func content(_ pinned: PinnedGameSnapshot) -> some View {
        switch family {
        case .accessoryInline:
            Text(inline(pinned))
        case .accessoryCircular:
            circular(pinned)
        #if os(watchOS)
        case .accessoryCorner:
            circular(pinned)
        #endif
        default:
            rectangular(pinned)
        }
    }

    private func rectangular(_ pinned: PinnedGameSnapshot) -> some View {
        HStack(spacing: 6) {
            MiniBoard(fen: pinned.state.fen, lastMoveUCI: pinned.state.lastMove, appearance: .watchWidget)
            VStack(alignment: .leading, spacing: 1) {
                line(pinned, color: .white)
                line(pinned, color: .black)
                if let result = ChessFormat.result(status: pinned.state.status) {
                    Text(result).font(.caption2.weight(.semibold)).monospacedDigit()
                } else if let move = pinned.state.moveLabel {
                    Text(move).font(.caption2).monospacedDigit().lineLimit(1)
                }
            }
        }
        .widgetAccentable()
        .accessibilityLabel(Text(inline(pinned)))
    }

    private func line(_ pinned: PinnedGameSnapshot, color: PieceColor) -> some View {
        let running = !entry.clocksAreStale && pinned.state.clockRunningFor == (color == .white ? "white" : "black")
        let seconds = color == .white ? pinned.state.whiteClock : pinned.state.blackClock
        return HStack(spacing: 3) {
            Text(color == .white ? pinned.whiteName : pinned.blackName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            ClockChip(
                seconds: seconds,
                deadline: running ? ChessFormat.deadline(seconds: seconds, asOf: pinned.state.asOf) : nil,
                compact: true
            )
        }
    }

    private func circular(_ pinned: PinnedGameSnapshot) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            if let result = ChessFormat.result(status: pinned.state.status) {
                Text(result).font(.caption2.weight(.semibold)).monospacedDigit()
            } else {
                Text(verbatim: "\(ChessFormat.moveNumber(ply: pinned.state.ply))")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
        }
        // `widgetLabel` takes a string here, not a `Text`: it is the curved caption a corner or
        // circular accessory draws around the gauge.
        .widgetLabel("\(pinned.whiteName) – \(pinned.blackName)")
        .accessibilityLabel(Text(inline(pinned)))
    }

    private var empty: some View {
        Text("No pinned game", comment: "Watch widget placeholder")
            .font(.caption2)
            .foregroundStyle(ChessTVPalette.muted)
    }

    private func inline(_ pinned: PinnedGameSnapshot) -> String {
        let names = "\(pinned.whiteName) – \(pinned.blackName)"
        if let result = ChessFormat.result(status: pinned.state.status) { return "\(names) \(result)" }
        guard let move = pinned.state.moveLabel else { return names }
        return "\(names) · \(move)"
    }
}

extension BoardAppearance {
    /// Always from White's side on the wrist, and never with coordinates: a 30-point board has no
    /// room for them and a glance has no time to work out which way round it is.
    static var watchWidget: BoardAppearance {
        var appearance = BoardAppearance.fromAppGroup()
        appearance.showsCoordinates = false
        appearance.orientation = .white
        return appearance
    }
}

extension PinnedGameSnapshot {
    static let watchPlaceholder = PinnedGameSnapshot(
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
