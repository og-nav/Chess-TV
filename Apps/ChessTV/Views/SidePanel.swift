// The column to the right of the board: opponent, move list, evaluation, player to move.
import SwiftUI
import ChessCore
import ChessUI
import EngineKit
import ImageryKit
import LichessKit

struct SidePanel: View {
    let model: AppModel

    /// How many numbered rows fit at 800 pt tall.
    private let visibleRows = 8

    var body: some View {
        VStack(spacing: 0) {
            PlayerRow(model: model, color: model.topColor)
                .padding(.bottom, 24)
                .overlay(alignment: .bottom) { rule }

            VStack(alignment: .leading, spacing: 28) {
                // An arena brings its leaderboard along; everything else leaves the move list
                // the whole width.
                HStack(alignment: .top, spacing: 28) {
                    moveList
                    if let standings = model.arenaStandings {
                        verticalRule
                        StandingsPanel(standings: standings, highlighted: model.boardPlayerNames)
                            .accessibilityIdentifier(UIID.Game.standings)
                    }
                }
                if model.showsEvalBar { evaluationRow }
            }
            .padding(.vertical, 24)
            .frame(maxHeight: .infinity)

            PlayerRow(model: model, color: model.bottomColor)
                .padding(.top, 24)
                .overlay(alignment: .top) { rule }
        }
    }

    private var rule: some View {
        Rectangle().fill(Palette.line).frame(height: 2)
    }

    private var verticalRule: some View {
        Rectangle().fill(Palette.line).frame(width: 2).frame(maxHeight: .infinity)
    }

    // MARK: - Move list

    private var moveList: some View {
        let rows = Array(model.game.moveRows.suffix(visibleRows))
        let latest = model.game.moveHistory.last
        return VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("No moves yet")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(rows, id: \.number) { row in
                    HStack(spacing: 0) {
                        Text("\(row.number).")
                            .frame(width: 64, alignment: .leading)
                            .foregroundStyle(Palette.faint)
                        cell(row.white, isLatest: row.white == latest)
                        cell(row.black, isLatest: row.black == latest)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(UIID.Game.moveRow(row.number))
                }
            }
        }
        .font(.system(size: 28))
        .monospacedDigit()
        // The panel is wider than the mockup's; without a cap the two move columns drift apart.
        .frame(maxWidth: 560, alignment: .leading)
        // The rows stay their own elements: one combined blob of eight rows reads badly and says
        // nothing about which move is which.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move list")
        .accessibilityIdentifier(UIID.Game.moveList)
    }

    private func cell(_ entry: MoveEntry?, isLatest: Bool) -> some View {
        Text(entry?.san ?? "\u{2026}")
            .lineLimit(1)
            .foregroundStyle(entry == nil ? Palette.faint : (isLatest ? Palette.ink : Palette.moveText))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isLatest && entry != nil ? Palette.panel : .clear)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Evaluation

    private var evaluationRow: some View {
        VStack(spacing: 0) {
            rule
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(model.game.evaluationText ?? "\u{2013}\u{2013}")
                        .font(.system(size: 40))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                    Text(principalVariation)
                        .font(.system(size: 24))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(depthText)
                    .font(.system(size: 24))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Palette.muted)
            .padding(.top, 20)
        }
    }

    /// The first three moves of the engine line in SAN, walked forward from the evaluated
    /// position. Falls back to the UCI text for any move SAN cannot resolve.
    private var principalVariation: String {
        guard let evaluation = model.game.evaluation, !evaluation.principalVariation.isEmpty else { return "" }
        let line = evaluation.principalVariation.prefix(3)
        guard var position = try? Position(fen: evaluation.positionFEN) else { return line.joined(separator: " ") }
        var parts: [String] = []
        for uci in line {
            guard let move = SAN.move(forUCI: uci, in: position), let san = SAN.notation(for: move, in: position) else {
                parts.append(uci)
                break
            }
            parts.append(san)
            position = position.making(move)
        }
        return parts.joined(separator: " ")
    }

    private var depthText: String {
        guard let evaluation = model.game.evaluation else { return "Stockfish 19 \u{00B7} thinking" }
        return "Stockfish 19 \u{00B7} depth \(evaluation.depth)"
    }
}

/// One player: portrait (broadcasts only), color dot, optional title chip, name, rating, flag,
/// and the clock.
struct PlayerRow: View {
    let model: AppModel
    let color: PieceColor

    private var player: PlayerInfo? { model.game.player(color) }
    private var isToMove: Bool { model.game.position?.sideToMove == color }
    /// Portraits only make sense where a FIDE id can exist: broadcast boards.
    private var showsPortrait: Bool {
        if case .broadcastBoard = model.game.source { return true }
        return false
    }

    private static let portraitSide: Double = 88

    /// The photographer FIDE credits for this portrait, when there is both a portrait and a name.
    private var photoCredit: String? {
        guard model.portraitURL(for: color) != nil else { return nil }
        guard let credit = model.photoCredit(for: color) else { return nil }
        return "Photo: \(credit)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            if showsPortrait {
                VStack(spacing: 6) {
                    RemoteImage(
                        portraitURL: model.portraitURL(for: color),
                        maxPixelSize: Self.portraitSide * 2,
                        name: player?.name ?? ""
                    )
                    .frame(width: Self.portraitSide, height: Self.portraitSide)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 2))
                    // FIDE names the photographer for some portraits and not others. Where it
                    // does, the credit travels with the picture: it is a condition of using it,
                    // not a nicety, and this is the only place the picture is shown large.
                    if let credit = photoCredit {
                        Text(credit)
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(width: Self.portraitSide + 40)
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Circle()
                        .fill(color == .white ? Color(hex: 0xEDE8D9) : Color(hex: 0x33392D))
                        .overlay(Circle().strokeBorder(color == .white ? Color(hex: 0xA7AB98) : Color(hex: 0x7D866D), lineWidth: 2))
                        .frame(width: 16, height: 16)
                    if let title = player?.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.accent))
                            .foregroundStyle(Palette.ground)
                    }
                    Text(player?.name ?? "\u{2014}")
                        .font(.system(size: 40))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .layoutPriority(1)
                    if let rating = player?.rating {
                        Text("\(rating)")
                            .font(.system(size: 24))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                    }
                    // Broadcasts carry a federation; the TV feed does not. The flag stands in for
                    // the code when we know it, since the row has no room for both beside a name.
                    if let federation = model.federation(for: color), !federation.isEmpty {
                        if let flag = model.flag(for: color) {
                            Text(flag)
                                .font(.system(size: 28))
                                .fixedSize()
                                .accessibilityLabel(Federations.name(for: federation) ?? federation)
                        } else {
                            Text(federation)
                                .font(.system(size: 22, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Palette.faint)
                        }
                    }
                }
                Text(subtitle)
                    .font(.system(size: 22))
                    .tracking(1.76)
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, showsPortrait ? 0 : 30)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(model.displayedClock(color) ?? "\u{2013}:\u{2013}\u{2013}")
                    .font(.system(size: 72, weight: .light))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(isToMove && model.game.isLive ? Palette.accent : Palette.ink)
                if model.clockIsEstimated(color) {
                    Text("ESTIMATED")
                        .font(.system(size: 20))
                        .tracking(1.6)
                        .foregroundStyle(Palette.amber)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(UIID.Game.clock(color == .white ? "white" : "black"))
    }

    private var subtitle: String {
        let name = color == .white ? "WHITE" : "BLACK"
        return isToMove ? "\(name) \u{00B7} TO MOVE" : name
    }
}
