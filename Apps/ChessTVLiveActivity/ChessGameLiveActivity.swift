// The Live Activity: one broadcast game, on the Lock Screen, in the Dynamic Island, in StandBy
// and — through `supplementalActivityFamilies` — in the watch's Smart Stack.
//
// The clocks are the interesting part. A widget's process is not running between updates, so a
// clock that counted down in code would be frozen at whatever it said when the push landed. Every
// running clock here is a `Text(timerInterval:)`, which the system animates on its own from a
// deadline; a clock that is *not* running — the side not on move, and both clocks once the game
// has a result — is plain text, so a finished game never shows a countdown.
import ActivityKit
import SwiftUI
import WidgetKit
import ChessCore
import ChessUI
import FollowKit

struct ChessGameLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChessGameAttributes.self) { context in
            LockScreenActivityView(attributes: context.attributes, state: context.state)
                .widgetURL(context.attributes.game.gameURL)
                .activityBackgroundTint(ChessTVPalette.ground)
                .activitySystemActionForegroundColor(ChessTVPalette.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandPlayer(
                        name: context.attributes.whiteName,
                        title: context.attributes.whiteTitle,
                        seconds: context.state.whiteClock,
                        deadline: context.state.whiteDeadline
                    )
                    .padding(.leading, 12)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandPlayer(
                        name: context.attributes.blackName,
                        title: context.attributes.blackTitle,
                        seconds: context.state.blackClock,
                        deadline: context.state.blackDeadline,
                        alignment: .trailing
                    )
                    .padding(.trailing, 12)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 12) {
                        MiniBoard(
                            fen: context.state.fen,
                            lastMoveUCI: context.state.lastMove,
                            appearance: appearance(for: context.attributes)
                        )
                        .frame(width: 70, height: 70)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(context.attributes.tourName)
                                .font(.caption2)
                                .foregroundStyle(ChessTVPalette.muted)
                                .lineLimit(1)
                            Text(context.attributes.roundName)
                                .font(.caption2)
                                .foregroundStyle(ChessTVPalette.muted)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                if let move = context.state.moveLabel {
                                    Text(move)
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(ChessTVPalette.ink)
                                        .lineLimit(1)
                                }
                                ResultChip(status: context.state.status, compact: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                ChessIslandMark(state: context.state, showsSide: true)
                    .frame(width: 34, height: 22)
            } compactTrailing: {
                RunningClock(state: context.state, compact: true)
                    .dynamicTypeSize(.medium)
                    .frame(width: 58, alignment: .trailing)
            } minimal: {
                ChessIslandMark(state: context.state, showsSide: false)
                    .frame(width: 22, height: 22)
            }
            .widgetURL(context.attributes.game.gameURL)
            .keylineTint(ChessTVPalette.accent)
        }
        // `.small` is the watch's Smart Stack, `.medium` the phone's Lock Screen and StandBy. With
        // these declared, `LockScreenActivityView` gets an `activityFamily` to lay itself out by
        // and the system mirrors the activity to a paired watch on its own.
        .supplementalActivityFamilies([.small, .medium])
    }

    /// The board colours come from the App Group; the *orientation* comes from the attributes,
    /// captured when the game was pinned, because turning the phone's board around mid-activity
    /// should not silently turn the Lock Screen's around too.
    private func appearance(for attributes: ChessGameAttributes) -> BoardAppearance {
        var appearance = BoardAppearance.fromAppGroup()
        appearance.orientation = attributes.orientationIsWhite ? .white : .black
        appearance.showsCoordinates = false
        return appearance
    }
}

private func toMoveLabel(_ state: ChessGameActivityState) -> String {
    switch state.runningColor {
    case "white": String(localized: "White to move", comment: "Accessibility label")
    case "black": String(localized: "Black to move", comment: "Accessibility label")
    default: String(localized: "Game over", comment: "Accessibility label")
    }
}

// MARK: - The Lock Screen, StandBy and the watch

struct LockScreenActivityView: View {
    let attributes: ChessGameAttributes
    let state: ChessGameActivityState

    /// `.small` is the watch's Smart Stack; `.medium` is the phone. The watch gets a tighter
    /// layout with no event line and a smaller board, because it is a 42 mm screen.
    @Environment(\.activityFamily) private var family

    private var appearance: BoardAppearance {
        var appearance = BoardAppearance.fromAppGroup()
        appearance.orientation = attributes.orientationIsWhite ? .white : .black
        appearance.showsCoordinates = false
        return appearance
    }

    /// Black above the board, White below, unless the board is turned around.
    private var topIsBlack: Bool { attributes.orientationIsWhite }

    var body: some View {
        HStack(alignment: .center, spacing: family == .small ? 8 : 12) {
            MiniBoard(fen: state.fen, lastMoveUCI: state.lastMove, appearance: appearance)
                .frame(width: family == .small ? 56 : 82, height: family == .small ? 56 : 82)

            VStack(alignment: .leading, spacing: family == .small ? 2 : 4) {
                if family != .small {
                    Text(verbatim: "\(attributes.tourName) · \(attributes.roundName)")
                        .font(.caption2)
                        .foregroundStyle(ChessTVPalette.muted)
                        .lineLimit(1)
                }
                if topIsBlack { playerLine(.black) } else { playerLine(.white) }
                if topIsBlack { playerLine(.white) } else { playerLine(.black) }
                HStack(spacing: 6) {
                    if let move = state.moveLabel {
                        Text(move)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(ChessTVPalette.ink)
                            .lineLimit(1)
                    }
                    ResultChip(status: state.status, compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(family == .small ? 8 : 12)
    }

    private func playerLine(_ color: PieceColor) -> some View {
        PlayerLine(
            name: color == .white ? attributes.whiteName : attributes.blackName,
            title: color == .white ? attributes.whiteTitle : attributes.blackTitle,
            rating: family == .small ? nil : (color == .white ? attributes.whiteRating : attributes.blackRating),
            seconds: color == .white ? state.whiteClock : state.blackClock,
            deadline: color == .white ? state.whiteDeadline : state.blackDeadline,
            isToMove: state.runningColor == (color == .white ? "white" : "black"),
            compact: family == .small
        )
    }
}

// MARK: - Dynamic Island pieces

private struct ChessIslandMark: View {
    let state: ChessGameActivityState
    let showsSide: Bool

    var body: some View {
        HStack(spacing: 2) {
            PieceAssets.image(set: .cburnett, piece: Piece(kind: .knight, color: .white))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
            if showsSide, let side = state.runningColor {
                Text(side == "white" ? "W" : "B")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(ChessTVPalette.accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Chess TV, \(toMoveLabel(state))"))
    }
}

private struct IslandPlayer: View {
    let name: String
    let title: String?
    let seconds: Int?
    let deadline: Date?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(ChessFormat.titled(name, title: title))
                .font(.caption2)
                .foregroundStyle(ChessTVPalette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            ClockChip(seconds: seconds, deadline: deadline, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// The clock of whichever side is on the move, for the compact trailing slot. Once the game is
/// over it shows the result instead — a countdown on a finished game is a lie the system would
/// happily keep animating.
private struct RunningClock: View {
    let state: ChessGameActivityState
    let compact: Bool

    var body: some View {
        if state.isFinished {
            Text(ChessFormat.result(status: state.status) ?? "—")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ChessTVPalette.ink)
        } else {
            ClockChip(
                seconds: state.runningColor == "black" ? state.blackClock : state.whiteClock,
                deadline: state.runningColor == "black" ? state.blackDeadline : state.whiteDeadline,
                compact: compact
            )
        }
    }
}

#if DEBUG
private enum ActivityLayoutSamples {
    static var attributes: ChessGameAttributes {
        ChessGameAttributes(game: ChessGameAttributesPayload(
            roundId: "preview-round", gameId: "preview-game", tourName: "Tata Steel Masters",
            roundName: "Round 5", whiteName: "Carlsen", blackName: "Nepomniachtchi",
            whiteTitle: "GM", blackTitle: "GM", whiteRating: 2839, blackRating: 2789
        ))
    }

    static var whiteToMove: ChessGameActivityState {
        ChessGameActivityState(fen: "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
            lastMove: "b8c6", san: "Nc6", ply: 4, whiteClock: 3812, blackClock: 745,
            clockRunningFor: "white", status: "*", asOf: Date())
    }

    static var blackToMove: ChessGameActivityState {
        var state = whiteToMove
        state.clockRunningFor = "black"
        return state
    }

    static var finished: ChessGameActivityState {
        var state = whiteToMove
        state.status = "1-0"
        state.clockRunningFor = nil
        return state
    }
}

#Preview("Aligned clocks", as: .content, using: ActivityLayoutSamples.attributes) {
    ChessGameLiveActivity()
} contentStates: {
    ActivityLayoutSamples.whiteToMove
    ActivityLayoutSamples.blackToMove
    ActivityLayoutSamples.finished
}

#Preview("Compact chess and clock", as: .dynamicIsland(.compact), using: ActivityLayoutSamples.attributes) {
    ChessGameLiveActivity()
} contentStates: {
    ActivityLayoutSamples.whiteToMove
    ActivityLayoutSamples.blackToMove
}

#Preview("Expanded game", as: .dynamicIsland(.expanded), using: ActivityLayoutSamples.attributes) {
    ChessGameLiveActivity()
} contentStates: {
    ActivityLayoutSamples.whiteToMove
    ActivityLayoutSamples.finished
}
#endif
