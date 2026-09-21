// The pieces the game screen is made of.
import SwiftUI
import ChessCore
import ChessUI
import FollowKit
import GameSessionKit
import ImageryKit
import LichessKit

// MARK: - A player and their clock

struct PlayerRow: View {
    let color: PieceColor
    let session: GameSession
    var fideID: Int? = nil

    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.dynamicTypeSize) private var typeSize

    private var player: PlayerInfo? { session.game.player(color) }

    var body: some View {
        HStack(spacing: 10) {
            portrait
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let title = player?.title, !title.isEmpty {
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Palette.accent)
                    }
                    Text(player?.name ?? "\u{2014}")
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let flag = session.flag(for: color) {
                        Text(flag).font(.headline).decorative()
                    }
                }
                HStack(spacing: 6) {
                    if let rating = player?.rating {
                        Text("\(rating)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Palette.muted)
                    }
                    if let federation = session.federation(for: color) {
                        Text(federation)
                            .font(.caption)
                            .foregroundStyle(Palette.faint)
                    }
                }
                // FIDE credits a photographer for some portraits. Where it does, the credit is
                // shown wherever the portrait is: it comes with the picture.
                if let credit = photoCredit {
                    Text(credit)
                        .font(.caption2)
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let fideID, fideID > 0 {
                Button {
                    InteractionFeedback.confirmation()
                    let follow = app.follows.add(.player(fideId: fideID))
                    navigator.push(.followDetail(target: follow.target))
                    if app.follows.hasServer, app.registrar.permission == .notDetermined {
                        Task { await app.registrar.requestPermission() }
                    }
                } label: {
                    Image(systemName: app.follows.isFollowing(.player(fideId: fideID)) ? "bell.fill" : "bell")
                        .frame(minWidth: 32, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Alerts for \(player?.name ?? "this player")")
                .accessibilityIdentifier(UIID.Game.playerBell(color == .white ? "white" : "black"))
            }
            clock
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .panelCard(corner: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The photographer's credit, only while the portrait it belongs to is on screen: at an
    /// accessibility type size the portrait is dropped, and a credit for a picture nobody can
    /// see is noise in a row that is already tight.
    private var photoCredit: String? {
        guard typeSize < .accessibility1, session.portraitURL(for: color) != nil else { return nil }
        guard let credit = session.photoCredit(for: color) else { return nil }
        return "Photo: \(credit)"
    }

    @ViewBuilder
    private var portrait: some View {
        // The portrait is decoration beside a name that is already spoken, and it is the first
        // thing worth dropping when the type size grows.
        if typeSize < .accessibility1 {
            RemoteImage(
                portraitURL: session.portraitURL(for: color),
                maxPixelSize: 160,
                name: player?.name ?? ""
            )
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .decorative()
        }
    }

    private var clock: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(session.displayedClock(color) ?? "\u{2013}:\u{2013}\u{2013}")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(isRunning ? Palette.ink : Palette.faint)
                .lineLimit(1)
                .accessibilityIdentifier(UIID.Game.clock(color == .white ? "white" : "black"))
            if session.clockIsEstimated(color) {
                Text("ESTIMATED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.amber)
            }
        }
    }

    private var isRunning: Bool {
        session.game.clocks?.sideToMove == color && session.game.finished == nil
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let title = player?.title, !title.isEmpty { parts.append(title) }
        parts.append(player?.name ?? "unknown player")
        if let rating = player?.rating { parts.append("rated \(rating)") }
        parts.append(color == .white ? "White" : "Black")
        if let clock = session.displayedClock(color) { parts.append("clock \(clock)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Scrubbing

struct ScrubBar: View {
    let session: GameSession

    private var total: Int { session.game.moveHistory.count }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                InteractionFeedback.selection()
                session.setViewedPly(ScrubTimeline.previous(session.viewedPly, total: total))
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(total == 0 || session.viewedPly == 0)
            .accessibilityLabel("Previous move")
            .accessibilityIdentifier(UIID.Game.scrubPrevious)

            Text(ScrubTimeline.label(viewed: session.viewedPly, history: session.game.moveHistory))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(isLive ? Palette.accent : Palette.ink)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .accessibilityLabel(isLive ? "Showing the live position" : "Showing \(ScrubTimeline.label(viewed: session.viewedPly, history: session.game.moveHistory))")
                .accessibilityIdentifier(UIID.Game.scrubLabel)

            Button {
                InteractionFeedback.selection()
                session.setViewedPly(ScrubTimeline.next(session.viewedPly, total: total))
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(isLive)
            .accessibilityLabel("Next move")
            .accessibilityIdentifier(UIID.Game.scrubNext)

            Button("Live") { InteractionFeedback.selection(); session.setViewedPly(nil) }
                .font(.subheadline.weight(.semibold))
                .disabled(isLive)
                .accessibilityHint("Returns the board to the position being played")
                .accessibilityIdentifier(UIID.Game.scrubLive)
        }
        .buttonStyle(.bordered)
        .tint(Palette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .panelCard(corner: 10)
    }

    private var isLive: Bool { session.viewedPly == nil }
}

// MARK: - Controls

struct GameControls: View {
    let session: GameSession
    let destination: GameDestination

    @Environment(AppEnvironment.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
            if needsRepinning {
                Text(LiveActivityController.shared.areActivitiesEnabled
                    ? "Live Activity ended. Pin again to resume updates."
                    : "Live Activity ended. Enable Live Activities in iOS Settings to pin this game again.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("live-activity-ended")
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if session.engineSupported {
            Button {
                InteractionFeedback.selection()
                session.toggleEngine()
            } label: {
                Label(app.settings.engineEnabled ? "Engine on" : "Engine off", systemImage: "cpu")
            }
            .buttonStyle(.bordered)
            .tint(app.settings.engineEnabled ? Palette.accent : Palette.faint)
            .accessibilityHint("Stockfish evaluates the position on this device")
            .accessibilityIdentifier(UIID.Game.engine)
        }

        Button {
            InteractionFeedback.tap()
            session.toggleFlipBoard()
        } label: {
            Label(
                session.boardOrientation == .white ? "Watch as Black" : "Watch as White",
                systemImage: "arrow.up.arrow.down"
            )
        }
        .buttonStyle(.bordered)
        .tint(Palette.accent)
        .accessibilityIdentifier(UIID.Game.flip)

        if let pin = pinPayload, LiveActivityController.shared.areActivitiesEnabled {
            Button {
                InteractionFeedback.tap()
                Task { await togglePin(pin) }
            } label: {
                Label(isPinned ? "Unpin" : (needsRepinning ? "Pin again" : "Pin to Lock Screen"), systemImage: isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.bordered)
            .tint(Palette.accent)
            .accessibilityHint("Shows this board on the Lock Screen and the watch, with the clocks running")
            .accessibilityIdentifier(UIID.Game.pin)
        }

        if let url = lichessURL {
            Link(destination: url) {
                Label("Open on lichess.org", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .tint(Palette.muted)
            .navigationFeedback()
            .accessibilityIdentifier(UIID.Game.lichess)
        }
    }

    private var isPinned: Bool {
        guard case .broadcastBoard(_, let gameId) = destination.source else { return false }
        return LiveActivityController.shared.isRunning
            && LiveActivityController.shared.pinned?.gameId == gameId
    }

    private var needsRepinning: Bool {
        guard case .broadcastBoard(_, let gameId) = destination.source,
              session.game.finished == nil, !isPinned else { return false }
        return LiveActivityController.shared.endedUnexpectedlyGameId == gameId
    }

    private func togglePin(_ pin: (game: ChessGameAttributesPayload, state: ChessGameActivityState)) async {
        if isPinned {
            await LiveActivityController.shared.unpin()
            app.syncWatch()
            return
        }
        do {
            _ = try await LiveActivityController.shared.pin(pin.game, state: pin.state)
            app.syncWatch()
        } catch {
            // The system refuses for its own reasons — activities turned off for the app, too
            // many running, Low Power Mode. Nothing on this screen depends on it, so the button
            // simply does not change state.
            mobileLog.notice("Could not pin the board: \(String(describing: error), privacy: .public)")
        }
    }

    /// The board as the Live Activity wants it. Nil until the feed has given us a position, and
    /// nil for anything that is not a broadcast board: a Lichess TV game is replaced every few
    /// minutes and would leave a Lock Screen activity for a game nobody is playing.
    private var pinPayload: (game: ChessGameAttributesPayload, state: ChessGameActivityState)? {
        guard case .broadcastBoard(let roundId, let gameId) = destination.source,
              session.game.position != nil else { return nil }
        let game = ChessGameAttributesPayload(
            roundId: roundId,
            gameId: gameId,
            tourName: session.sourceTitle,
            roundName: destination.title ?? "",
            whiteName: session.game.white?.name ?? "White",
            blackName: session.game.black?.name ?? "Black",
            whiteTitle: session.game.white?.title,
            blackTitle: session.game.black?.title,
            whiteRating: session.game.white?.rating,
            blackRating: session.game.black?.rating,
            orientationIsWhite: session.boardOrientation == .white
        )
        guard let state = PinnedActivity.state(of: session) else { return nil }
        return (game, state)
    }

    private var lichessURL: URL? {
        switch destination.source {
        case .broadcastBoard(let roundId, let gameId):
            URL(string: "https://lichess.org/broadcast/-/-/\(roundId)/\(gameId)")
        case .arena(let tournamentId):
            URL(string: "https://lichess.org/tournament/\(tournamentId)")
        case .tvChannel:
            session.game.gameId.flatMap { URL(string: "https://lichess.org/\($0)") }
        }
    }
}

/// The Live Activity's moving part, read off the session.
///
/// The phone pushes this itself while the game screen is open; the server pushes the same shape
/// per move when the app is closed. We age the received clocks to the fresh `asOf` timestamp,
/// so pinning between moves does not rewind the clock. The activity counts down from there.
@MainActor
enum PinnedActivity {
    static func state(of session: GameSession) -> ChessGameActivityState? {
        guard let position = session.game.position else { return nil }
        let clocks = session.game.clocks
        let finished = session.game.finished
        return ChessGameActivityState(
            LiveActivityState(
                fen: position.fen,
                lastMove: session.game.moveHistory.last?.uci,
                san: session.game.moveHistory.last?.san,
                ply: session.game.moveHistory.count,
                whiteClock: ClockDisplay.remainingSeconds(for: .white, clocks: clocks,
                    isLive: session.game.clocksAreLive && finished == nil, now: .now),
                blackClock: ClockDisplay.remainingSeconds(for: .black, clocks: clocks,
                    isLive: session.game.clocksAreLive && finished == nil, now: .now),
                clockRunningFor: finished == nil && session.game.clocksAreLive ? (position.sideToMove == .white ? "white" : "black") : nil,
                status: finished?.result ?? (finished == nil ? "*" : "finished"),
                asOf: .now
            )
        )
    }
}

// MARK: - Evaluation

struct EvaluationLine: View {
    let session: GameSession

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        if app.settings.engineEnabled, session.engineSupported {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(session.viewedEvaluationText ?? "\u{2013}")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.ink)
                    if let depth = session.viewedEvaluation?.depth {
                        Text("depth \(depth)")
                            .font(.caption)
                            .foregroundStyle(Palette.faint)
                    }
                    Spacer(minLength: 0)
                }
                let line = PrincipalVariation.text(
                    session.viewedEvaluation?.principalVariation ?? [],
                    from: session.viewedPosition ?? session.game.position
                )
                if !line.isEmpty {
                    Text(line)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Palette.moveText)
                        .lineLimit(2)
                        .accessibilityLabel("Engine line: \(line)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .panelCard(corner: 10)
            .accessibilityIdentifier(UIID.Game.evaluation)
        }
    }
}

// MARK: - Move list

struct MoveList: View {
    let session: GameSession
    /// A column in the side panel, or a strip under the board on a phone in portrait.
    var isVertical: Bool

    var body: some View {
        if session.game.moveHistory.isEmpty {
            Text("No moves yet")
                .font(.footnote)
                .foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .panelCard(corner: 10)
        } else if isVertical {
            verticalList
        } else {
            horizontalStrip
        }
    }

    private var rows: [NumberedMoveRow] { NumberedMoveRow.rows(from: session.game.moveHistory) }

    private var verticalList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(row.number).")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Palette.faint)
                                .frame(width: 34, alignment: .trailing)
                            moveCell(row.white)
                            moveCell(row.black)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(10)
            }
            .frame(maxHeight: 320)
            .panelCard(corner: 10)
            .accessibilityIdentifier(UIID.Game.moveList)
            .onChange(of: session.game.moveHistory.count) { _, _ in
                guard session.viewedPly == nil else { return }
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }

    private var horizontalStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(session.game.moveHistory.enumerated()), id: \.offset) { index, entry in
                        HStack(spacing: 4) {
                            if entry.color == .white {
                                Text("\(entry.moveNumber).")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Palette.faint)
                            }
                            moveButton(entry, ply: ScrubTimeline.ply(forHistoryIndex: index))
                        }
                        .id(index)
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
            .panelCard(corner: 10)
            .accessibilityIdentifier(UIID.Game.moveList)
            .onChange(of: session.game.moveHistory.count) { _, count in
                guard session.viewedPly == nil, count > 0 else { return }
                withAnimation { proxy.scrollTo(count - 1, anchor: .trailing) }
            }
        }
    }

    private static let bottomID = "move-list-bottom"

    @ViewBuilder
    private func moveCell(_ move: PliedMove?) -> some View {
        if let move {
            moveButton(move.entry, ply: move.ply)
                .frame(minWidth: 62, alignment: .leading)
        } else {
            Text(" ").frame(minWidth: 62, alignment: .leading)
        }
    }

    private func moveButton(_ entry: MoveEntry, ply: Int) -> some View {
        let isSelected = session.viewedPly == ply
        return Button {
            InteractionFeedback.selection()
            session.setViewedPly(isSelected ? nil : ply)
        } label: {
            Text(entry.san)
                .font(.footnote.weight(isSelected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? Palette.ground : Palette.moveText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isSelected ? Palette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BoardSpeech.move(number: entry.moveNumber, color: entry.color, san: entry.san))
        .accessibilityHint("Shows the board after this move")
        .accessibilityIdentifier(UIID.Game.move(ply: ply))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Arena standings

struct StandingsPanel: View {
    let standings: ArenaStandings
    let highlighting: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Standings")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(standings.playerCountText)
                    .font(.caption)
                    .foregroundStyle(Palette.faint)
            }
            ForEach(standings.rows) { row in
                HStack(spacing: 8) {
                    Text("\(row.rank)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Palette.faint)
                        .frame(width: 22, alignment: .trailing)
                    if let title = row.title, !title.isEmpty {
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Palette.accent)
                    }
                    Text(row.name)
                        .font(.footnote.weight(highlighting.contains(row.name) ? .bold : .regular))
                        .foregroundStyle(row.withdrawn ? Palette.faint : Palette.ink)
                        .lineLimit(1)
                    if row.onStreak {
                        Image(systemName: "flame.fill")
                            .font(.caption2)
                            .foregroundStyle(Palette.amber)
                            .decorative()
                    }
                    Spacer(minLength: 0)
                    Text("\(row.score)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.moveText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label(for: row))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(corner: 10)
    }

    private func label(for row: ArenaStanding) -> String {
        var parts = ["\(row.rank)", row.name, "\(row.score) points"]
        if row.onStreak { parts.append("on a streak") }
        if row.withdrawn { parts.append("withdrawn") }
        return parts.joined(separator: ", ")
    }
}
