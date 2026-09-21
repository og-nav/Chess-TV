// The arena leaderboard, beside the move list: the ten rows Lichess sends on page one.
import SwiftUI
import LichessKit

struct StandingsPanel: View {
    let standings: ArenaStandings
    /// The two players on the board right now; their rows are marked.
    let highlighted: Set<String>

    /// Ten of these plus the header fit inside the 800 pt board's height.
    private static let rowHeight: Double = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(standings.rows) { row in
                self.row(row)
            }
            Spacer(minLength: 0)
        }
        // The rows stay separate elements inside the group: one combined blob of ten rows would
        // be unreadable, and a test could not check a row on its own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Standings")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Standings")
                .font(.system(size: 24))
                .fixedSize()
            Spacer(minLength: 8)
            Text(standings.playerCountText)
                .font(.system(size: 24))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
    }

    private func row(_ standing: ArenaStanding) -> some View {
        let isOnBoard = highlighted.contains(standing.name)
        return HStack(spacing: 10) {
            Text("\(standing.rank)")
                .font(.system(size: 22))
                .monospacedDigit()
                .foregroundStyle(Palette.faint)
                .frame(width: 34, alignment: .trailing)
            if let title = standing.title, !title.isEmpty {
                titleChip(title)
            }
            Text(standing.name)
                .font(.system(size: 24))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(standing.score)")
                .font(.system(size: 28))
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 44, alignment: .trailing)
            // The slot is always there, so the scores stay in one column.
            Group {
                if standing.onStreak {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.accent)
                        .accessibilityLabel("on a streak")
                }
            }
            .frame(width: 24, alignment: .leading)
        }
        // A player who withdrew is still ranked, but is not playing: the row steps back.
        .foregroundStyle(standing.withdrawn ? Palette.faint : Palette.ink)
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOnBoard ? Palette.panel : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(UIID.Game.standingsRow(standing.rank))
    }

    /// The same chip the player rows use for a FIDE title.
    private func titleChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.accent))
            .foregroundStyle(Palette.ground)
    }
}
