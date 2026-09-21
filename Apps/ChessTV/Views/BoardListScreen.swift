// The boards of one broadcast round. Select a board to watch it; Back returns to the home screen.
import SwiftUI
import ChessCore
import LichessKit
import ImageryKit

struct BoardListScreen: View {
    let roundId: String
    /// What the shelf card said, so the header has a name before the fetch lands.
    var tournamentName: String?

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var monitor: BroadcastRoundMonitor
    /// The place picture from Wikipedia, used only when the tour has no banner of its own.
    @State private var placeImage: WikipediaImage?
    @FocusState private var focused: String?

    init(roundId: String, tournamentName: String? = nil) {
        self.roundId = roundId
        self.tournamentName = tournamentName
        _monitor = State(initialValue: BroadcastRoundMonitor(roundId: roundId))
    }

    private var round: BroadcastTournament? { monitor.round }
    private var boards: [BroadcastBoard] { monitor.boards }
    private var connectionText: String {
        monitor.isConnected ? "Live" : (monitor.errorMessage == nil ? "Updating…" : "Reconnecting…")
    }

    private var orderedBoards: [(offset: Int, element: BroadcastBoard)] {
        let numbered = Array(boards.enumerated())
        return numbered.filter { $0.element.isOngoing } + numbered.filter { !$0.element.isOngoing }
    }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                header
                content
            }
            .padding(.horizontal, Metrics.extraHorizontalPadding)
            .padding(.top, 8)
        }
        .foregroundStyle(Palette.ink)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await monitor.run()
        }
        .task(id: round?.location) {
            guard round?.imageURL == nil, placeImage == nil, let location = round?.location else { return }
            placeImage = await WikipediaImageClient.shared.image(forPlace: location)
        }
    }

    // MARK: - Header

    private static let bannerSize = CGSize(width: 240, height: 108)

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            banner
            VStack(alignment: .leading, spacing: 8) {
                Text(round?.name ?? tournamentName ?? "Broadcast")
                    .font(.system(size: 44, weight: .semibold))
                    .tracking(-1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier(UIID.Boards.title)
                Text(subtitle)
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if round?.roundOngoing == true || boards.contains(where: \.isOngoing) {
                if monitor.isConnected {
                    LiveDot()
                } else {
                    Text(connectionText)
                        .font(.system(size: 24))
                        .foregroundStyle(Palette.muted)
                        .accessibilityLabel(monitor.errorMessage == nil
                            ? "Connecting to round updates"
                            : "Round updates disconnected. Reconnecting.")
                }
            }
            Text(model.wallClock, format: .dateTime.hour().minute())
                .font(.system(size: 26))
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .fixedSize()
        }
        .frame(minHeight: Self.bannerSize.height)
    }

    /// The tour banner, or a picture of the host city when the organiser gave none.
    @ViewBuilder
    private var banner: some View {
        let url = round?.imageURL ?? placeImage?.imageURL
        RemoteImage(bannerURL: url, maxPixelSize: Self.bannerSize.width * 2, title: nil)
            .frame(width: Self.bannerSize.width, height: Self.bannerSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line, lineWidth: 2))
            .accessibilityHidden(true)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let round {
            parts.append(round.roundName)
            if let format = round.format, !format.isEmpty { parts.append(format) }
            if let location = round.location, !location.isEmpty { parts.append(location) }
        }
        if parts.isEmpty { parts.append("Loading\u{2026}") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Boards

    @ViewBuilder
    private var content: some View {
        if let error = monitor.errorMessage, boards.isEmpty {
            message(error)
        } else if !monitor.hasLoaded {
            message("Loading\u{2026}")
        } else if boards.isEmpty {
            message(emptyText)
        } else {
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)],
                    spacing: 24
                ) {
                    ForEach(orderedBoards, id: \.element.id) { index, board in
                        boardCard(board, number: index + 1)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .defaultFocus($focused, orderedBoards.first?.element.gameId)

        }
    }

    private var emptyText: String {
        guard let startsAt = round?.roundStartsAt else { return "This round has not started yet" }
        return "Round starts at \(HomeShelves.time(startsAt))"
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 40)
    }

    private func boardCard(_ board: BroadcastBoard, number: Int) -> some View {
        NavigationLink(value: Route.game(destination(for: board, number: number))) {
            HStack(alignment: .center, spacing: 24) {
                Text("\(number)")
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text(playerLine(board))
                        .font(.system(size: 28))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(statusLine(board))
                            .font(.system(size: 24))
                            .monospacedDigit()
                            .foregroundStyle(board.isOngoing ? Palette.accent : Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(height: 164, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HomeCardButtonStyle())
        .focused($focused, equals: board.gameId)
        // The grid only exists once the fetch lands, so the first card claims focus as it appears.
        // First means first on screen, which is the board still being played, not board 1: the
        // remote has to land where the eye does.
        .onAppear {
            if focused == nil, board.gameId == orderedBoards.first?.element.gameId { focused = board.gameId }
        }
        .accessibilityLabel("Board \(number): \(playerLine(board))")
        .accessibilityIdentifier(UIID.Boards.card(board.gameId))
    }

    private func destination(for board: BroadcastBoard, number: Int) -> GameDestination {
        GameDestination(
            source: .broadcastBoard(roundId: roundId, gameId: board.gameId),
            title: SourceTitle.board(
                tournament: round?.name ?? tournamentName ?? "Broadcast",
                round: round?.roundName ?? "",
                boardNumber: number
            ),
            whiteFederation: board.white?.federation,
            blackFederation: board.black?.federation,
            whiteFideId: board.white?.fideId,
            blackFideId: board.black?.fideId,
            whitePhoto: board.white?.photo,
            blackPhoto: board.black?.photo,
            preview: GamePreview(board: board, receivedAt: monitor.clockAnchor(for: board.gameId),
                                 clocksRunning: monitor.canTick(board: board))
        )
    }

    private func playerLine(_ board: BroadcastBoard) -> String {
        guard let white = board.white, let black = board.black else {
            return board.name.isEmpty ? "Board" : board.name
        }
        return "\(name(white)) \u{2013} \(name(black))"
    }

    private func name(_ player: BroadcastPlayer) -> String {
        let extras = [player.title, player.rating.map(String.init), player.federation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !extras.isEmpty else { return player.name }
        return "\(player.name) (\(extras.joined(separator: ", ")))"
    }

    private func statusLine(_ board: BroadcastBoard) -> String {
        var parts = [board.isOngoing ? connectionText : board.status]
        let side = (try? Position(fen: board.fen))?.sideToMove
        let reading = ClockReading(
            whiteSeconds: board.white?.clockSeconds,
            blackSeconds: board.black?.clockSeconds,
            receivedAt: monitor.clockAnchor(for: board.gameId),
            sideToMove: side ?? .white
        )
        let now = monitor.clockNow
        let clocks = [PieceColor.white, .black].compactMap {
            ClockDisplay.remainingSeconds(for: $0, clocks: reading,
                isLive: monitor.canTick(board: board), now: now)
        }
        if clocks.count == 2 {
            parts.append("\(ClockDisplay.text(clocks[0])) \u{2013} \(ClockDisplay.text(clocks[1]))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

}
